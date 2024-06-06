# Cloudflare dynamic DNS updater tool

Auto-update your Cloudflare DNS A record.

Author: Adam Matthews

## WHAT IT DOES

- It compares the current external (WAN) IP address of the machine with the DNS IP record of the domain.
- If different, it updates the domain's DNS A record at cloudflare to relect the machine's IP.
- Similar to DuckDNS / No-IP / DynDNS but for your own domain on Cloudflare.

## INSTALLATION

- Save the script here: /usr/local/bin/******
- Set permissions: "sudo chmod 600 /usr/local/bin/******

## AUTO-RUN

To automatically execute it every 10 minuites, add the following cron-job ("sudo crontab -e"):
    #Track changes to public IP and update Cloudflare DNS record.
     */10 * * * * /usr/local/bin/cloudflare-ddns.sh

## NOTIFICATIONS

When script is executed manually (e.g. from command line)...
- Success - Result and IPv4 address is output to terminal.
- Error - Result and reason for failure is output to terminal.

When executed as a cron-job...
- Success - Will remain silent / no notification.
- Error - The admin will be mailed.
- Assuming the machine has the ability to send mail (e.g. via Postfix / External SMTP).
