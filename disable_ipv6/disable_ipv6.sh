#!/bin/bash

# Variables
api_token="YOUR_API_TOKEN"
zone_id="YOUR_ZONE_ID"
email="YOUR_EMAIL"

# Disable IPv6
curl -X PATCH "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/ipv6" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ${api_token}" \
     --data '{"value":"off"}'
