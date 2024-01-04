#!/usr/bin/env bash

# Enable Bash strict mode
# https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# Debug function to print messages when DEBUG_LEVEL is '1' or '2'
debug() {
    if [[ $DEBUG_LEVEL -gt 0 ]]; then
        # Print debug messages
        echo "$1"
    fi
}

# Error function to print error and exit script
error() {
    # Print error and exit
    echo -e "$1" >&2
    exit 1
}

# Get script directory
script_dir=$(dirname "$0")

# Import enviroment variables (api key etc) from .env file
if source "$script_dir/.env"; then
    # Validate debug level after sourcing .env file
    debug_level_allowed=(0 1 2)
    if ! [[ " ${debug_level_allowed[*]} " =~ " $DEBUG_LEVEL " ]]; then
        error "Invalid DEBUG_LEVEL: '$DEBUG_LEVEL'. Must be one of: ${debug_level_allowed[*]}."
    else
        debug "Check 1  (of 10) passed. Required file '.env' loaded sucessfully."
    fi
else
    error "Error: failed to source file: $script_dir/.env"
fi

# Set verbose output when DEBUG_LEVEL=2
if [[ $DEBUG_LEVEL -eq 2 ]]; then
    echo "Debugging is enabled. This can fill your logs fast."
    set -x
fi

# Check if the script is already running
if ps ax | grep "$0" | grep -v "$$" | grep bash | grep -v grep > /dev/null; then
    error "Error: The script is already running."
else
    debug "Check 2  (of 10) passed. Script is not already running."
fi

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    error "Error: Required utility; 'jq' is not installed."
else
    debug "Check 3  (of 10) passed. Required utility; 'jq' is installed."
fi

# Check if cURL is installed
if ! command -v curl >/dev/null 2>&1; then
    error "Error: Required utility; 'cURL' is not installed."
else
    debug "Check 4  (of 10) passed. Required utility; 'cURL' is installed."
fi

# Set cURL parameters
curl_timeout=10  # How many seconds before cURL times out
curl_retries=3   # Maximum number of retries
curl_wait=5      # Seconds to wait between retries

# Check the subdomain (DNS_RECORD variable) in the .env file
# Check if the dns_record field (subdomain) contains dot
if [[ $DNS_RECORD == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $DNS_RECORD != *.$ZONE_NAME ]]; then
        error "Error: The Zone in DNS_RECORD does not match the defined Zone in ZONE_NAME."
    else
        debug "Check 5  (of 10) passed. DNS zone to check/update: $DNS_RECORD."
    fi
# check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $DNS_RECORD =~ ^[a-zA-Z0-9-]+$ ]]; then
    error "Error: The DNS Record contains illegal charecters - e.g: ., @, %, *, _"
# if the dns_record (subdomain) is not complete, complete it
else
    DNS_RECORD="$DNS_RECORD.$ZONE_NAME"
    debug debug "Check 5  (of 10) passed. DNS zone to check/update: $DNS_RECORD."
fi

# Attempt to obtain the Cloudflare User ID.
user_id=""
for (( i=0; i<curl_retries; i++ )); do
    user_id=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
                -H "Authorization: Bearer $API_KEY" \
                -H "Content-Type: application/json" \
                | jq -r '.result | .id')
    if [ -n "$user_id" ]; then
        break # Exit loop if user_id is obtained
    fi
    # Retry if unsuccessful.
    sleep "$curl_wait"
done

# Check if User ID has been obtained sucessfully
if [ -n "$user_id" ]; then
    debug "Check 6  (of 10) passed. Cloudflare User ID:     $user_id."
else
    error "Error: There is a problem with the Cloudflare API token."
fi

# # Attempt to obtain the Cloudflare Zone ID
zone_id=""
for (( i=0; i<curl_retries; i++ )); do
    zone_id=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME&status=active" \
                -H "Content-Type: application/json" \
                -H "X-Auth-Email: $EMAIL" \
                -H "Authorization: Bearer $API_KEY" \
                | jq -r '.result[0].id')
    if [ -n "$zone_id" ]; then
        break # Exit loop if zone_id is obtained
    fi
    # Retry if unsuccessful
    sleep "$curl_wait"
done

# Check if the Zone ID has been obtained successfully
if [ -n "$zone_id" ]; then
    debug "Check 7  (of 10) passed. Cloudflare Zone ID:     $zone_id."
else
    error "Error: There is a problem with getting the Zone ID (sub-domain) or the email address (username)."
fi

# Attempt to obtain the JSON response for the DNS zone A record (Via Cloudflare API)
dns_record_json=""
for (( i=0; i<curl_retries; i++ )); do
    dns_record_json=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$DNS_RECORD" \
                -H "Content-Type: application/json" \
                -H "X-Auth-Email: $EMAIL" \
                -H "Authorization: Bearer $API_KEY")
    if [ -n "$dns_record_json" ]; then
        break # Exit loop if response is obtained
    fi
    # Retry if unsuccessful
    sleep "$curl_wait"
done

# Extract the DNS Record A ID from the JSON response
dns_record_a_id=$(echo "$dns_record_json" | jq -r '.result[0].id')

# Check if DNS Record A ID has been obtained successfully
if [ -n "$dns_record_a_id" ]; then
    debug "Check 8  (of 11) passed. Cloudflare A-record ID: $dns_record_a_id."
else
    error "Error: There was a problem when attempting to obtain the DNS A Record ID via Cloudflare API."
fi

# Parse the DNS zone A-record IP (Via Cloudflare API)
dns_record_a_ip=$(echo "$dns_record_json" | jq -r '.result[0].content')

# Check if DNS Zone A-record IP has been obtained successfully
if [ -n "$dns_record_a_ip" ]; then
    debug "Check 9  (of 11) passed. DNS Zone A-record IP (via Cloudflare API):  $dns_record_a_ip."
else
    error "Error: There was a problem when attempting to obtain the DNS A-record IP via Cloudflare API."
fi

# Get the DNS A Record IP
check_record_ipv4=$(dig -t a +short ${DNS_RECORD} | tail -n1 | xargs)

# Check if A Record IP has been retrieved sucessfully
if [ -z "${check_record_ipv4}" ]; then
    error "Error: No A Record is setup for ${DNS_RECORD}."
else
    debug "Check 10 (of 11) passed. DNS zone A-record IP (via 'domain groper'): $check_record_ipv4."
fi

# Get the machine's WAN IP
timeout_seconds=10
machine_ipv4=$(
    curl -s https://checkip.amazonaws.com --max-time $timeout_seconds ||
    curl -s https://api.ipify.org --max-time $timeout_seconds ||
    curl -s https://ipv4.icanhazip.com/ --max-time $timeout_seconds
)
# Check the IPv4 is obtainable
if [ -z "$machine_ipv4" ]; then
    error "Error: Can't get external IPv4"
fi
# Define valid IPv4 (using Regex)
valid_ipv4='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$'
# Check the IPv4 is valid
if ! [[ "$machine_ipv4" =~ $valid_ipv4 ]]; then
    error "Error: IP Address returned was invalid: '$machine_ipv4'"
else
    debug "Check 11 (of 11) passed. Machine's public (WAN) IP is:               $machine_ipv4."
fi

# Check if the machine's IPv4 is different to the Cloudflare IPv4
if [ $dns_record_a_ip != $machine_ipv4 ]; then
    # If different, update the A record
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$(echo $dns_record_a_id | jq -r '{"result"}[] | .[0] | .id')" \
            -H "Content-Type: application/json" \
            -H "X-Auth-Email: $EMAIL" \
            -H "Authorization: Bearer $API_KEY" \
            --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD\",\"content\":\"$machine_ipv4\",\"ttl\":1,\"proxied\":false}" \
            | jq -r '.errors'
    # Wait a few minutes to allow the DNS change to propogate / become active
    sleep_seconds=300
    debug "Paused for $sleep_seconds seconds. (Allows IP update to propogate before final check)..."
    sleep $sleep_seconds
    # Check the IPv4 change has been applied sucessfully
    if [ $check_record_ipv4 != $machine_ipv4 ]; then
        error "Error: A change of IP was attempted but was unsuccessful. Current Machine IP: $machine_ipv4 Domain IP: $check_record_ipv4"
    else
        debug "Success: IPv4 updated on Cloudflare with the new value of: $check_record_ipv4."
        exit 0
    fi
else
    debug "Success: (No change) The machine IPv4 matches the domain IPv4: $check_record_ipv4."
    exit 0
    fi
fi
