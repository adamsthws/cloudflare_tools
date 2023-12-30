#!/usr/bin/env bash

# Enable Bash strict mode
# https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

## Import enviroment variables (api key etc)
source .env

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
    debug "Check 1 (of 7) passed. Script is not already running, proceeding..."
fi

# Check if jq is installed
check_jq=$(which jq)
if [ -z "${check_jq}" ]; then
    error "Error: jq is not installed."
else
    debug "Check 2 (of 7) passed. 'jq' is installed, proceeding..."
fi

# Check the subdomain
# Check if the dns_record field (subdomain) contains dot
if [[ $DNS_RECORD == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $DNS_RECORD != *.$ZONE_NAME ]]; then
        error "Error: The Zone in DNS_RECORD does not match the defined Zone in ZONE_NAME."
    else
        debug "Check 3 (of 7) passed. DNS zone to check/update: $DNS_RECORD, proceeding..."
    fi
# check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $DNS_RECORD =~ ^[a-zA-Z0-9-]+$ ]]; then
    error "Error: The DNS Record contains illegal charecters - e.g: ., @, %, *, _"
# if the dns_record (subdomain) is not complete, complete it
else
    DNS_RECORD="$DNS_RECORD.$ZONE_NAME"
    debug debug "Check 3 (of 7) passed. DNS zone to check/update: $DNS_RECORD, proceeding..."
fi

# Get the DNS Record IP
check_record_ipv4=$(dig -t a +short ${DNS_RECORD} | tail -n1)

# Get the machine's WAN IP
ipv4=$(curl -s -X GET https://checkip.amazonaws.com)

# Get Cloudflare User ID
user_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type:application/json" \
            | jq -r '{"result"}[] | .id'
        )

# Check public IPv4 is obtainable
##### MAKE THIS A MORE THOROUGH CHECK
if ! [ $ipv4 ]; then
    error "Error: Unable to get any public IPv4 address."
else
    debug "Check 4 (of 7) passed. Machine's public (WAN) IP is: $ipv4, proceeding..."
fi

# Check if the user API is valid and the email is correct
if [ $user_id ]; then
    debug "Check 5 (of 7) passed. Cloudflare User ID is: $user_id, proceeding..."
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME&status=active" \
                -H "Content-Type: application/json" \
                -H "X-Auth-Email: $EMAIL" \
                -H "Authorization: Bearer $API_KEY" \
                | jq -r '{"result"}[] | .[0] | .id'
            )
    # check if the zone ID is avilable
    if [ $zone_id ]; then
        debug "Check 6 (of 7) passed. Cloudflare Zone ID is: $zone_id, proceeding..."
        # check if there is IPv4
        if [ $ipv4 ]; then                       #### THIS IS DUPLICATED FROM ABOVE #####
            # Check if A Record exists
            if [ -z "${check_record_ipv4}" ]; then
                error "Error: No A Record is setup for ${DNS_RECORD}."
            fi
            dns_record_a_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$DNS_RECORD"  \
                            -H "Content-Type: application/json" \
                            -H "X-Auth-Email: $EMAIL" \
                            -H "Authorization: Bearer $API_KEY"
                            )
            dns_record_a_ip=$(echo $dns_record_a_id |  jq -r '{"result"}[] | .[0] | .content')
            debug "Check 7 (of 7) passed. Cloudflare Domain IP is: $check_record_ipv4, proceeding..."
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
                sleep 180
                # Check the IPv4 change has been applied sucessfully
                if [ $check_record_ipv4 != $ipv4 ]; then
                    error "Error: A change of IP was attempted but was unsuccessful. \nCurrent IP: $ipv4 \nCloudflare IP: $check_record_ipv4"
                else
                    # If debug level is set, output result
                    debug "Success: IPv4 updated on Cloudflare with the new value of: $ipv4."
                    exit 0
                fi
            else
                # If debug level is set, output result
                debug "Success: (No change) The current IPv4 address matches the IP at Cloudflare: $ipv4."
                exit 0
                fi
            fi
        fi
    else
        error "Error: There is a problem with getting the Zone ID (sub-domain) or the email address (username)."
    fi
else
    error "Error: There is a problem with the Cloudflare API token."
fi