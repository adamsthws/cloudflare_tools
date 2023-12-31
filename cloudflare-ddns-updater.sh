#!/usr/bin/env bash

# Enable Bash strict mode
# https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Debug function to print messages if debug level is 1 or 2
debug() {
    if [[ $DEBUG_LEVEL -gt 0 ]]; then
        echo "$1"
    fi
}

# Error function to print error and exit script
error() {
    echo -e "$1" >&2
    exit 1
}

# Set debug mode for debug level 2
if [[ $DEBUG_LEVEL -eq 2 ]]; then
    echo "Debugging is enabled. This can fill your logs fast."
    set -x
fi

# Check if the script is already running
if ps ax | grep "$0" | grep -v "$$" | grep bash | grep -v grep > /dev/null; then
    error "Error: The script is already running."
else
    debug "Check 1 (of 8) passed. Script is not already running, proceeding..."
fi

## Import enviroment variables (api key etc)
####### Add a check and debug message for this ######
source "$(dirname "$0")/.env"

# Check if jq is installed
check_jq=$(which jq)
if [ -z "${check_jq}" ]; then
    error "Error: jq is not installed."
else
    debug "Check 2 (of 8) passed. 'jq' is installed, proceeding..."
fi

# Check the subdomain
# Check if the dns_record field (subdomain) contains dot
if [[ $DNS_RECORD == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $DNS_RECORD != *.$ZONE_NAME ]]; then
        error "Error: The Zone in DNS_RECORD does not match the defined Zone in ZONE_NAME."
    else
        debug "Check 3 (of 8) passed. DNS zone to check/update: $DNS_RECORD, proceeding..."
    fi
# check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $DNS_RECORD =~ ^[a-zA-Z0-9-]+$ ]]; then
    error "Error: The DNS Record contains illegal charecters - e.g: ., @, %, *, _"
# if the dns_record (subdomain) is not complete, complete it
else
    DNS_RECORD="$DNS_RECORD.$ZONE_NAME"
    debug debug "Check 3 (of 8) passed. DNS zone to check/update: $DNS_RECORD, proceeding..."
fi

# Get the DNS A Record IP
check_record_ipv4=$(dig -t a +short ${DNS_RECORD} | tail -n1)
# Check if A Record exists
if [ -z "${check_record_ipv4}" ]; then
    error "Error: No A Record is setup for ${DNS_RECORD}."
else
    debug "Check 4 (of 8) passed. DNS zone A record is: $check_record_ipv4, proceeding..."
fi

# Get the machine's WAN IP
ipv4=$(curl -s -X GET https://checkip.amazonaws.com)
# Check the machine has a valid WAN IP               ##### MAKE THIS A MORE THOROUGH CHECK ##########
if [ $ipv4 ]; then
    debug "Check 5 (of 8) passed. Machine's public (WAN) IP is: $ipv4, proceeding..."
else
    error "Error: Unable to get any public IPv4 address."
fi

# Get Cloudflare User ID
user_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type:application/json" \
            | jq -r '{"result"}[] | .id'
        )
# Check if the API is valid and the email is correct
if [ $user_id ]; then
    debug "Check 6 (of 8) passed. Cloudflare User ID is: $user_id, proceeding..."
else
    error "Error: There is a problem with the Cloudflare API token."
fi

# Get Cloudflare Zone ID
zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME&status=active" \
            -H "Content-Type: application/json" \
            -H "X-Auth-Email: $EMAIL" \
            -H "Authorization: Bearer $API_KEY" \
            | jq -r '{"result"}[] | .[0] | .id'
        )
# Check if the Zone ID is avilable
if [ $zone_id ]; then
    debug "Check 7 (of 8) passed. Cloudflare Zone ID is: $zone_id, proceeding..."
else
    error "Error: There is a problem with getting the Zone ID (sub-domain) or the email address (username)."
fi

# Get DNS zone A record IP (Via Cloudflare API)
dns_record_a_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$DNS_RECORD"  \
                -H "Content-Type: application/json" \
                -H "X-Auth-Email: $EMAIL" \
                -H "Authorization: Bearer $API_KEY"
                )
dns_record_a_ip=$(echo $dns_record_a_id |  jq -r '{"result"}[] | .[0] | .content')
# Check if the IP can be retrieved via API
if [ $dns_record_a_ip ]; then
    debug "Check 8 (of 8) passed. Zone A record IP (via Cloudflare API) is: $dns_record_a_ip, proceeding..."
else
    error "Error: There is a problem with getting the zone A record IP via Cloudflare API."
fi

# Check if the machine's IPv4 is different to the Cloudflare IPv4
if [ $dns_record_a_ip != $ipv4 ]; then
    # If different, update the A record
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$(echo $dns_record_a_id | jq -r '{"result"}[] | .[0] | .id')" \
            -H "Content-Type: application/json" \
            -H "X-Auth-Email: $EMAIL" \
            -H "Authorization: Bearer $API_KEY" \
            --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD\",\"content\":\"$ipv4\",\"ttl\":1,\"proxied\":false}" \
    | jq -r '.errors'
    # Wait for 180 seconds to allow the DNS change to propogate / become active
    sleep_seconds=300
    debug "Paused for $sleep_seconds seconds. (Allows IP update to propogate before final check)..."
    sleep $sleep_seconds
    # Check the IPv4 change has been applied sucessfully
    if [ $check_record_ipv4 != $ipv4 ]; then
        error "Error: A change of IP was attempted but was unsuccessful. Current Machine IP: $ipv4 Domain IP: $check_record_ipv4"
    else
        debug "Success: IPv4 updated on Cloudflare with the new value of: $check_record_ipv4."
        exit 0
    fi
else
    debug "Success: (No change) The machine IPv4 matches the domain IPv4: $check_record_ipv4."
    exit 0
    fi
fi