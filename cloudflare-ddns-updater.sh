#!/usr/bin/env bash

# Enable Bash strict mode
# https://olivergondza.github.io/2019/10/01/bash-strict-mode.html
set -euo pipefail
trap 's=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

## Import enviroment variables (api key etc)
source .env

## API token
## (imported from .env file)
api_token=$API_KEY

## The email address associated with the Cloudflare account; e.g. email@gmail.com
## (imported from .env file)
email=$EMAIL

## the zone (domain) should be modified; e.g. example.com
## (imported from .env file)
zone_name=$ZONE_NAME

## the dns record (sub-domain) that needs to be modified; e.g. sub.example.com
## (imported from .env file)
dns_record=$DNS_RECORD

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
fi

# Check if jq is installed
check_jq=$(which jq)
if [ -z "${check_jq}" ]; then
    error "Error: jq is not installed."
fi

# Check the subdomain
# Check if the dns_record field (subdomain) contains dot
if [[ $dns_record == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $dns_record != *.$zone_name ]]; then
        error "Error: The Zone in DNS Record does not match the defined Zone."
    fi
# check if the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $dns_record =~ ^[a-zA-Z0-9-]+$ ]]; then
    error "Error: The DNS Record contains illegal charecters - e.g: ., @, %, *, _"
# if the dns_record (subdomain) is not complete, complete it
else
    dns_record="$dns_record.$zone_name"
fi

# Get the DNS Record IP
check_record_ipv4=$(dig -t a +short ${dns_record} | tail -n1)

# Get the machine's WAN IP
ipv4=$(curl -s -X GET https://checkip.amazonaws.com)

# Get Cloudflare User ID
user_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type:application/json" \
            | jq -r '{"result"}[] | .id'
        )

# Check public IPv4 is obtainable
##### MAKE THIS A MORE THOROUGH CHECK
if ! [ $ipv4 ]; then
    error "Error: Unable to get any public IPv4 address."
fi

# Check if the user API is valid and the email is correct
if [ $user_id ]; then
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active" \
                -H "Content-Type: application/json" \
                -H "X-Auth-Email: $email" \
                -H "Authorization: Bearer $api_token" \
                | jq -r '{"result"}[] | .[0] | .id'
            )
    # check if the zone ID is avilable
    if [ $zone_id ]; then
        # check if there is IPv4
        if [ $ipv4 ]; then
            # Check if A Record exists
            if [ -z "${check_record_ipv4}" ]; then
                error "Error: No A Record is setup for ${dns_record}."
            fi
            dns_record_a_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$dns_record"  \
                            -H "Content-Type: application/json" \
                            -H "X-Auth-Email: $email" \
                            -H "Authorization: Bearer $api_token"
                            )
            dns_record_a_ip=$(echo $dns_record_a_id |  jq -r '{"result"}[] | .[0] | .content')
            # Check if the machine's IPv4 is different to the Cloudflare IPv4
            if [ $dns_record_a_ip != $ipv4 ]; then
                # If different, update the A record
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$(echo $dns_record_a_id | jq -r '{"result"}[] | .[0] | .id')" \
                        -H "Content-Type: application/json" \
                        -H "X-Auth-Email: $email" \
                        -H "Authorization: Bearer $api_token" \
                        --data "{\"type\":\"A\",\"name\":\"$dns_record\",\"content\":\"$ipv4\",\"ttl\":1,\"proxied\":false}" \
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