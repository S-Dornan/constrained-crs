#!/usr/bin/env bash
# Run on Proxmox Host
# Provisions the OSS-CRS Cleanroom (Ephemeral) and the Log Vault (Persistent)

TEMPLATE_ID=9001
STORAGE="local-lvm"
VM1_SNIPPET_PATH="local:snippets/cloud-init-logging.yaml"
VM2_SNIPPET_PATH="local:snippets/cloud-init-cleanroom.yaml"
VM1_ID="301"
VM2_ID="302"

# Accept CLI arguments for resource starvation, with fallback defaults
TARGET_CORES=${1:-8}
TARGET_RAM=${2:-32768}
TARGET_RATE=${3:-20}

# ==========================================
# Clean Slate Safeguard (Cleanroom ONLY)
# ==========================================
echo "[*] Checking for existing cleanroom instance ($VM2_ID)..."
if qm status "$VM2_ID" >/dev/null 2>&1; then
  echo "[!] Found existing Cleanroom VM $VM2_ID. Tearing down for a clean run..."
  qm stop "$VM2_ID" >/dev/null 2>&1 || true
  sleep 2
  qm destroy "$VM2_ID"
fi

echo "[*] Staging Cloud-Init Snippets..."
mkdir -p /var/lib/vz/snippets
cp cloud-init-logging.yaml /var/lib/vz/snippets/cloud-init-logging.yaml
cp cloud-init-cleanroom.yaml /var/lib/vz/snippets/cloud-init-cleanroom.yaml

echo "[*] Initializing CRS Cleanroom Architecture..."

# ==========================================
# 1. Log Vault Provisioning (Persistent)
# ==========================================
if qm status "$VM1_ID" >/dev/null 2>&1; then
  echo "[*] Log Vault ($VM1_ID) already exists. Power-cycling to flush port 9001..."
  qm stop "$VM1_ID" >/dev/null 2>&1 || true
  sleep 2
  qm start "$VM1_ID"
  echo "Log Vault rebooted. Socket cleared."
else
  echo "[*] Log Vault not found. Provisioning crs-log-vault ($VM1_ID)..."
  qm clone $TEMPLATE_ID $VM1_ID --name crs-log-vault --full true --storage $STORAGE
  
  echo "Applying static, lightweight footprint to Log Vault..."
  qm set $VM1_ID \
    --memory 2048 \
    --cores 1 \
    --agent 1 \
    --net0 virtio,bridge=vmbr0 \
    --net1 virtio,bridge=vmbr1

  qm set $VM1_ID \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=172.16.255.20/24 \
    --cicustom "user=$VM1_SNIPPET_PATH" \
    --tags "crs,experiment,logging"
    
  qm resize $VM1_ID scsi0 32G
  
  echo "Configuring Log Vault as Serial Receiver..."
  qm set $VM1_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=9001,server=on,wait=off -device isa-serial,chardev=serial_log"
  
  qm start $VM1_ID
  echo "crs-log-vault is booting!"
fi

# ==========================================
# Hypervisor Bridge Synchronization
# ==========================================
echo "Waiting for Log Vault hypervisor to bind port 9001..."
while ! ss -lptn | grep -q ":9001 "; do
  sleep 1
done
echo "Port 9001 is active. Proceeding with Cleanroom boot."

# ==========================================
# 2. Cleanroom Provisioning (Ephemeral)
# ==========================================
echo "[*] Provisioning crs-cleanroom ($VM2_ID)..."
qm clone $TEMPLATE_ID $VM2_ID --name crs-cleanroom --full true --storage $STORAGE

echo "Applying experimental starvation profile to Cleanroom..."
qm set $VM2_ID \
  --memory $TARGET_RAM \
  --cores $TARGET_CORES \
  --agent 1 \
  --net0 virtio,bridge=vmbr0,rate=$TARGET_RATE \
  --net1 virtio,bridge=vmbr1

qm set $VM2_ID \
  --ipconfig0 ip=dhcp \
  --ipconfig1 ip=172.16.255.21/24 \
  --cicustom "user=$VM2_SNIPPET_PATH" \
  --tags "crs,experiment,fuzzer"

qm resize $VM2_ID scsi0 32G

echo "Configuring Cleanroom as Serial Sender..."
qm set $VM2_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=9001 -device isa-serial,chardev=serial_log"

qm start $VM2_ID
echo "crs-cleanroom is booting!"

echo "[+] Architecture provisioned successfully."