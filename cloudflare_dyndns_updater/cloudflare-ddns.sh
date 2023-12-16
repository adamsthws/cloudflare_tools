#!/bin/bash

# This script acts as a DYNdns updater for a domain on Cloudflare.
# It compares the current external (WAN) IP address of the machine with the DNS IP record of the domain.
# If different, it updates the domain's DNS A record at cloudflare to relect the machine's IP.

# Save the script here: /usr/local/bin/cloudflare-ddns.sh
# Set permissions: "sudo chmod 100 /usr/local/bin/cloudflare-ddns.sh"

# To automatically execute it every 5 minuites, add the following to crontab ("sudo crontab -e"):
#    #Track changes to public IP and update Cloudflare DNS record.
#    */5 * * * * /usr/local/bin/cloudflare-ddns.sh

# Set initial data
## API token; e.g. FErgdfflw3wr59dfDce33-3D43dsfs3sddsFoD3
api_token="<your-cloudflare-api-token>"

## the email address associated with the Cloudflare account; e.g. email@gmail.com
email="<your-cloudflare-email-address>"

## the zone (domain) should be modified; e.g. example.com
zone_name="<your-cloudflare-domain>"

## the dns record (sub-domain) that needs to be modified; e.g. sub.example.com
dns_record="<your-full-cloudflare-sub-domain>"

#####                                        #####
#####  DO NOT EDIT ANYTHING BELOW THIS LINE  #####
#####                                        ##### 

# Check if the script is already running
if ps ax | grep "$0" | grep -v "$$" | grep bash | grep -v grep > /dev/null; then
    echo -e "Script Error (Cloudflare DYNdns updater script) \nThe script is already running."
    exit 1
fi

# Check if jq is installed
check_jq=$(which jq)
if [ -z "${check_jq}" ]; then
    echo -e "Script Error (Cloudflare DYNdns updater script) \njq is not installed. Install it by 'sudo apt install jq'."
    exit 1
fi

# Check the subdomain
# Check if the dns_record field (subdomain) contains dot
if [[ $dns_record == *.* ]]; then
    # if the zone_name field (domain) is not in the dns_record
    if [[ $dns_record != *.$zone_name ]]; then
        echo -e "Script Error (Cloudflare DYNdns updater script) \nThe Zone in DNS Record does not match the defined Zone; check it and try again."
        exit 1
    fi
# If the dns_record (subdomain) is not complete and contains invalid characters
elif ! [[ $dns_record =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo -e "Script Error (Cloudflare DYNdns updater script) \nThe DNS Record contains illegal charecters, i.e., @, %, *, _, etc.; fix it and run the script again."
    exit 1
# If the dns_record (subdomain) is not complete, complete it
else
    dns_record="$dns_record.$zone_name"
fi

# Check if DNS Records Exists
check_record_ipv4=$(dig -t a +short ${dns_record} | tail -n1)

# Get the basic data
ipv4=$(curl -s -X GET https://checkip.amazonaws.com)
user_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
               -H "Authorization: Bearer $api_token" \
               -H "Content-Type:application/json" \
          | jq -r '{"result"}[] | .id'
         )

# Check public IPv4 is obtainable
if [ $ipv4 ]; then
    # If running as chron stay silent. Otherwise output result.
    if [ -t 1 ] ; then
        echo -e "Current public IPv4 address: $ipv4"
    fi
else
    echo -e "Script Error (Cloudflare DYNdns updater script) \nUnable to get any public IPv4 address."
    exit 1
fi

# Check if the user API is valid and the email is correct
if [ $user_id ]; then
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active" \
                   -H "Content-Type: application/json" \
                   -H "X-Auth-Email: $email" \
                   -H "Authorization: Bearer $api_token" \
              | jq -r '{"result"}[] | .[0] | .id'
             )
    # Check if the zone ID is avilable
    if [ $zone_id ]; then
        # Check if there is an IP
        if [ $ipv4 ]; then
            # Check if A Record exists
            if [ -z "${check_record_ipv4}" ]; then
                echo -e "Script Error (Cloudflare DYNdns updater script) \nNo A Record is setup for ${dns_record}."
                exit 1
            fi
            dns_record_a_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$dns_record"  \
                                   -H "Content-Type: application/json" \
                                   -H "X-Auth-Email: $email" \
                                   -H "Authorization: Bearer $api_token"
                             )
            dns_record_a_ip=$(echo $dns_record_a_id |  jq -r '{"result"}[] | .[0] | .content')
            # If current IPv4 is different than the actual IPv4
            if [ $dns_record_a_ip != $ipv4 ]; then
                # Change the A record
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$(echo $dns_record_a_id | jq -r '{"result"}[] | .[0] | .id')" \
                     -H "Content-Type: application/json" \
                     -H "X-Auth-Email: $email" \
                     -H "Authorization: Bearer $api_token" \
                     --data "{\"type\":\"A\",\"name\":\"$dns_record\",\"content\":\"$ipv4\",\"ttl\":1,\"proxied\":false}" \
                | jq -r '.errors'
                # If running as chron stay silent. Otherwise output result.
                if [ -t 1 ] ; then
                    echo -e "Script Notification (Cloudflare DYNdns updater script) \nUpdated: IPv4 successfully set on Cloudflare with the value of: $ipv4."
                fi
                exit 0
            else
                # If running as chron stay silent. Otherwise output result.
                if [ -t 1 ] ; then
                    echo -e "Script Notification (Cloudflare DYNdns updater script) \nNo change: The current IPv4 address matches the IP at Cloudflare: $ipv4."
                fi
                exit 0
            fi
        fi

    else
        echo -e "Script Error (Cloudflare DYNdns updater script) \nThere is a problem with getting the Zone ID (sub-domain) or the email address (username)."
        exit 1
    fi
else
    echo -e "Script Error (Cloudflare DYNdns updater script) \nThere is a problem with the API token."
    exit 1
fi
