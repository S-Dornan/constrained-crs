#!/usr/bin/env bash
#
# Copyright (C) 2026 Sam Dornan
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
#
# Backplane & SSH Validation Script

# ==========================================
# Load Environment Variables
# ==========================================
if [ -f ".env" ]; then
  source .env
else
  echo "[!] FATAL: .env file not found. Cannot load Proxmox configuration."
  exit 1
fi

# Extract IP without the CIDR notation (e.g., 172.16.255.20/24 -> 172.16.255.20)
VAULT_IP=${VM1_IP%/*}

echo "======================================================="
echo "INITIATING BACKPLANE & SSH VALIDATION TEST"
echo "======================================================="

# 1. Build the architecture using minimal resources for speed
./vm-config.sh 2 4096 20

# 2. Create a test payload on the Cleanroom
echo "[*] Creating dummy payload on the Cleanroom..."
qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "echo 'BACKPLANE_SECURE_AND_ROUTING' > /home/ubuntu/test-payload.txt"

# 3. Prepare the landing zone on the Log Vault
echo "[*] Preparing the Vault landing zone..."
qm guest exec $VM1_ID -- sudo -u ubuntu mkdir -p /home/ubuntu/vault-results/validation-test

# 4. Fire the payload across the isolated backplane using the injected SSH key
echo "[*] Executing Rsync over $VAULT_IP backplane..."
qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "rsync -avz -e 'ssh -o StrictHostKeyChecking=no' /home/ubuntu/test-payload.txt ubuntu@$VAULT_IP:/home/ubuntu/vault-results/validation-test/"

# 5. Verify the payload arrived intact
echo "[*] Verifying payload receipt on the Log Vault..."
# We capture the output of the 'cat' command on the Vault to see if the string matches
VERIFY=$(qm guest exec $VM1_ID -- sudo -u ubuntu cat /home/ubuntu/vault-results/validation-test/test-payload.txt | tr -d '\r\n')

if [[ "$VERIFY" == *"BACKPLANE_SECURE_AND_ROUTING"* ]]; then
  echo -e "\n[+] =========================================="
  echo "[+] SUCCESS: BACKPLANE AND SSH KEYS ARE FLAWLESS"
  echo "[+] =========================================="
else
  echo -e "\n[-] =========================================="
  echo "[-] FAILED: PAYLOAD DID NOT REACH THE VAULT"
  echo "[-] =========================================="
fi

# 6. Teardown
echo "[*] Tearing down the validation environment..."
qm stop $VM2_ID >/dev/null 2>&1 || true
qm destroy $VM2_ID >/dev/null 2>&1 || true

echo "[+] Cleanroom destroyed. You are cleared for launch."