# Monitoring stack

1. Remote monitoring stack will be Uptime Kuma push monitor behind cloudflare access (see standard Kuma Push monitors; customize this to run on Proxmox)
2. Local monitoring stack will be Wazuh. If possible, consider using that to monitor the VM itself from the outside.