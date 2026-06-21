#!/usr/bin/env bash
# Backplane & SSH Validation Script

VM1_ID=301
VM2_ID=302

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
echo "[*] Executing Rsync over 172.16.255.x backplane..."
qm guest exec $VM2_ID -- sudo -u ubuntu bash -c "rsync -avz -e 'ssh -o StrictHostKeyChecking=no' /home/ubuntu/test-payload.txt ubuntu@172.16.255.20:/home/ubuntu/vault-results/validation-test/"

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