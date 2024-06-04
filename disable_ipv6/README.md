# Cloudflare IPv6 Disabler Tool
This tool allows you to disable IPv6 for a specific zone in Cloudflare using the Cloudflare API. It uses a scoped API token with the necessary permissions to update the zone settings.

## Prerequisites

- A Cloudflare account.
- A scoped API token with the required permissions.
- The curl command-line tool.

## Create your API token

Log in to Cloudflare, go to the Cloudflare dashboard and navigate to the "My Profile" section...

  - Select "API Tokens" and then "Create Token".
  - Zone - Zone Settings - Read & Edit
  - Specify the specific zone(s) for which the token will be valid.
  - Save the token securely as it will be used in the script.
