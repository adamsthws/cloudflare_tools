#!/usr/bin/env bash

# Enable Bash 'strict mode'
# See: https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
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
        debug "Check 1  (of 11) passed. Required file '.env' loaded sucessfully."
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
    debug "Check 2  (of 11) passed. Script is not already running."
fi

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    error "Error: Required utility; 'jq' is not installed."
else
    debug "Check 3  (of 11) passed. Required utility; 'jq' is installed."
fi

# Check if cURL is installed
if ! command -v curl >/dev/null 2>&1; then
    error "Error: Required utility; 'cURL' is not installed."
else
    debug "Check 4  (of 11) passed. Required utility; 'cURL' is installed."
fi

# Set cURL parameters
curl_timeout=10  # How many seconds before cURL times out
curl_retries=3   # Maximum number of retries
curl_wait=5      # Seconds to wait between retries

# Check the subdomain (DNS_RECORD variable) in the .env file
# Check if the dns_record field (subdomain) contains dot and matches the zone name
if [[ $DNS_RECORD == *.* ]]; then
    if [[ $DNS_RECORD != *.$ZONE_NAME ]]; then
        error "Error: The Zone in DNS_RECORD does not match the defined Zone in ZONE_NAME."
    fi
# Check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $DNS_RECORD =~ ^[a-zA-Z0-9-]+$ ]]; then
    error "Error: The DNS Record contains illegal characters - e.g: ., @, %, *, _"
# If the dns_record (subdomain) is not complete, complete it
else
    DNS_RECORD="$DNS_RECORD.$ZONE_NAME"
fi
# Final confirmation/debug message
debug "Check 5  (of 11) passed. DNS zone to check/update: $DNS_RECORD."

# Attempt to obtain the Cloudflare User ID.
user_id=""
for (( i=0; i<curl_retries; i++ )); do
    user_id=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
                -H "Authorization: Bearer $API_TOKEN" \
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
    debug "Check 6  (of 11) passed. Cloudflare User ID:     $user_id."
else
    error "Error: There is a problem with the Cloudflare API token."
fi

# # Attempt to obtain the Cloudflare Zone ID
zone_id=""
for (( i=0; i<curl_retries; i++ )); do
    zone_id=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME&status=active" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $API_TOKEN" \
                | jq -r '.result[0].id')
    if [ -n "$zone_id" ]; then
        break # Exit loop if zone_id is obtained
    fi
    # Retry if unsuccessful
    sleep "$curl_wait"
done

# Check if the Zone ID has been obtained successfully
if [ -n "$zone_id" ]; then
    debug "Check 7  (of 11) passed. Cloudflare Zone ID:     $zone_id."
else
    error "Error: There is a problem with getting the Zone ID (sub-domain)."
fi

# Attempt to obtain the JSON response for the DNS zone A-record (Via Cloudflare API)
dns_record_json=""
for (( i=0; i<curl_retries; i++ )); do
    dns_record_json=$(curl -s -m "$curl_timeout" \
                -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$DNS_RECORD" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $API_TOKEN")
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
cf_a_record_ip=$(echo "$dns_record_json" | jq -r '.result[0].content')

# Define valid IPv4 (using Regex)
valid_ipv4='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$'

# Check if DNS Zone A-record IP has been obtained successfully and is valid
if [[ -n "$cf_a_record_ip" ]] && [[ "$cf_a_record_ip" =~ $valid_ipv4 ]]; then
    debug "Check 9  (of 11) passed. DNS Zone A-record IP (via Cloudflare API):   $cf_a_record_ip."
else
    error "Error: The DNS A-record IP is either invalid or could not be obtained from Cloudflare: '$cf_a_record_ip'"
fi

# Function to get the published IPv4 via dig
get_published_a_record_ipv4() {
    dig -t a +short ${DNS_RECORD} | tail -n1 | xargs
}

# Assign the published DNS A-record to a variable
published_a_record_ipv4=$(get_published_a_record_ipv4)

# Check if published A-record IP has been retrieved successfully and is valid
if [[ -n "$published_a_record_ipv4" ]] && [[ "$published_a_record_ipv4" =~ $valid_ipv4 ]]; then
    debug "Check 10 (of 11) passed. DNS zone A-record IP (via 'domain groper'):  $published_a_record_ipv4."
else
    error "Error: No valid A Record is set up for ${DNS_RECORD}, or the IP is invalid: '$published_a_record_ipv4'."
fi

# Get the machine's WAN IP (with multiple fallback options)
machine_ipv4=$(
    curl -s https://checkip.amazonaws.com  --max-time $curl_timeout ||
    curl -s https://api.ipify.org          --max-time $curl_timeout ||
    curl -s https://ipv4.icanhazip.com/    --max-time $curl_timeout
)

# Check if the machine's public IP has been retrieved sucessfully and is valid
if [[ -n "$machine_ipv4" ]] && [[ "$machine_ipv4" =~ $valid_ipv4 ]]; then
    debug "Check 11 (of 11) passed. Machine's public (WAN) IP:                   $machine_ipv4."
else
    error "Error: IP Address returned was invalid: '$machine_ipv4'"
fi

# Check if the machine's IPv4 is different to the Cloudflare IPv4
if [ "$cf_a_record_ip" != "$machine_ipv4" ]; then
    # If different, update the A record
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$dns_record_a_id" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $API_TOKEN" \
            --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD\",\"content\":\"$machine_ipv4\",\"ttl\":1,\"proxied\":false}")
    # Extract errors from the response
    error_message=$(echo "$response" | jq -r '.errors[]? | .message')
    if [ -n "$error_message" ]; then
        error "Error updating Cloudflare DNS A-record: $error_message"
    else
        debug "IPv4 update applied to DNS zone A-record with the new value of: $machine_ipv4."
        final_check_required="True"
    fi
else
    debug "Success: (No change) The machine IPv4 matches the domain IPv4: $published_a_record_ipv4."
    final_check_required="False"
    exit 0
fi

# Final check that the IPv4 update has taken effect
if [ "$final_check_required" == "True" ]; then
    attempts=20 # Repeat the check this many times
    sleep_seconds=15 # How long to wait between checks
    sleep $sleep_seconds # Pause before first check
    while [ $attempts -gt 0 ]; do
        # Fetch the current published A Record IP again
        published_a_record_ipv4=$(get_published_a_record_ipv4)
        debug "Checking if IPv4 update has taken effect. Published IP: $published_a_record_ipv4"
        if [ "$published_a_record_ipv4" == "$machine_ipv4" ]; then
            debug "Success: IPv4 updated on Cloudflare with the new value of: $published_a_record_ipv4."
            exit 0
        fi
        debug "IPv4 update hasn't taken effect yet. Checking again in $sleep_seconds seconds. ($attempts attempts remaining)"
        sleep $sleep_seconds
        attempts=$((attempts - 1))
    done

    error "Error: A change of IP was attempted but was unsuccessful. Current Machine IP: $machine_ipv4, Last checked Domain IP: $published_a_record_ipv4"
else
    debug "Success: (No change) The machine IPv4 matches the domain IPv4: $published_a_record_ipv4."
    exit 0
fi
