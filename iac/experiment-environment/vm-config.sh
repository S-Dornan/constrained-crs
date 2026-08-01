#!/usr/bin/env bash

# Copyright (C) 2026 Sam Dornan
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

# Run on Proxmox Host
# Provisions the OSS-CRS Cleanroom (Ephemeral) and the Log Vault (Persistent)

# ==========================================
# Load Environment Variables
# ==========================================
if [ -f ".env" ]; then
  source .env
else
  echo "[!] FATAL: .env file not found. Cannot load Proxmox configuration."
  exit 1
fi

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

# ==========================================
# Secret Injection (Architecture Observability & Auth)
# ==========================================
echo "[*] Injecting secrets into staged snippets..."

# Extract raw IPs without CIDR notation
VM1_IP_RAW=${VM1_IP%/*}
VM2_IP_RAW=${VM2_IP%/*}

# Map Proxmox serial interface name (default index 1 maps to ttyS1)
SERIAL_DEV="ttyS1"

# Inject IPs & Serial Port
sed -i "s|__VM1_IP_RAW__|$VM1_IP_RAW|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__VM1_IP_RAW__|$VM1_IP_RAW|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml
sed -i "s|__VM2_IP_RAW__|$VM2_IP_RAW|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml
sed -i "s|__SERIAL_DEV__|$SERIAL_DEV|g" /var/lib/vz/snippets/cloud-init-logging.yaml

# Inject System Password and Expiration Policy
sed -i "s|__DEFAULT_PASSWORD__|$DEFAULT_VM_PASSWORD|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__DEFAULT_PASSWORD__|$DEFAULT_VM_PASSWORD|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml
sed -i "s|__FORCE_PASSWORD_CHANGE__|$FORCE_PASSWORD_CHANGE|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__FORCE_PASSWORD_CHANGE__|$FORCE_PASSWORD_CHANGE|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml

# Log Vault Secrets
sed -i "s|__LOG_FILE__|$LOG_FILE|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__HEALTH_URL__|$HEALTH_PUSH_URL|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__STREAM_URL__|$STREAM_PUSH_URL|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__CF_ID__|$CF_CLIENT_ID|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__CF_SECRET__|$CF_CLIENT_SECRET|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__RCLONE_REMOTE_PATH__|$RCLONE_REMOTE_PATH|g" /var/lib/vz/snippets/cloud-init-logging.yaml
  
# Cleanroom Fuzzer Secrets
sed -i "s|__BASE_URL__|$CRSBENCH_LLM_UPSTREAM_BASE_URL|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml
sed -i "s|__GEMINI_API_KEY__|$CRSBENCH_LLM_UPSTREAM_API_KEY|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml

# 2. Handle Rclone Configuration
if [ -f "rclone.conf" ]; then
  echo "[*] Injecting Rclone configuration..."
  RCLONE_B64=$(base64 -w 0 rclone.conf)
  sed -i "s|__RCLONE_CONF_B64__|$RCLONE_B64|g" /var/lib/vz/snippets/cloud-init-logging.yaml
else
  echo "[!] WARNING: rclone.conf not found. Log syncing will be disabled."
  sed -i "s|__RCLONE_CONF_B64__||g" /var/lib/vz/snippets/cloud-init-logging.yaml
fi

# ==========================================
# 3. Handle Backplane SSH Keys (Data Exfiltration)
# ==========================================
echo "[*] Handling Backplane SSH Keys..."
if [ ! -f "crs-sync-key" ]; then
  echo "Generating new Ed25519 SSH keypair for backplane sync..."
  ssh-keygen -t ed25519 -f crs-sync-key -N "" -q
fi

SYNC_PUB=$(cat crs-sync-key.pub)
SYNC_PRIV_B64=$(base64 -w 0 crs-sync-key)

sed -i "s|__SYNC_PUB_KEY__|$SYNC_PUB|g" /var/lib/vz/snippets/cloud-init-logging.yaml
sed -i "s|__SYNC_PRIV_KEY_B64__|$SYNC_PRIV_B64|g" /var/lib/vz/snippets/cloud-init-cleanroom.yaml

echo "[*] Initializing CRS Cleanroom Architecture..."

# ==========================================
# 1. Log Vault Provisioning (Persistent)
# ==========================================
if qm status "$VM1_ID" >/dev/null 2>&1; then
  echo "[*] Log Vault ($VM1_ID) already exists. Power-cycling to flush port $SERIAL_PORT..."
  qm stop "$VM1_ID" >/dev/null 2>&1 || true
  sleep 2
  qm start "$VM1_ID"
  echo "Log Vault rebooted. Socket cleared."
else
  echo "[*] Log Vault not found. Provisioning crs-log-vault ($VM1_ID)..."
  qm clone $TEMPLATE_ID $VM1_ID --name crs-log-vault --full true --storage $STORAGE
  
  echo "Applying static, lightweight footprint to Log Vault..."
  qm set $VM1_ID \
    --memory 4096 \
    --cores 2 \
    --agent 1 \
    --net0 virtio,bridge=vmbr0,rate=$TARGET_RATE \
    --net1 virtio,bridge=vmbr1,rate=$TARGET_RATE

  qm set $VM1_ID \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=$VM1_IP \
    --cicustom "user=$VM1_SNIPPET_PATH" \
    --tags "crs,experiment,logging"
    
  qm resize $VM1_ID scsi0 32G
  
  echo "Configuring Log Vault as Serial Receiver..."
  qm set $VM1_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off -device isa-serial,chardev=serial_log,index=1"
  
  qm start $VM1_ID
  echo "crs-log-vault is booting!"
fi

# ==========================================
# Hypervisor Bridge Synchronization
# ==========================================
echo "Waiting for Log Vault hypervisor to bind port $SERIAL_PORT..."
while ! ss -lptn | grep -q ":$SERIAL_PORT "; do
  sleep 1
done
echo "Port $SERIAL_PORT is active. Proceeding with Log Vault boot sequence."

# ==========================================
# Strict Dependency Lock: Await Log Vault
# ==========================================
echo "Waiting for Log Vault QEMU Guest Agent to initialize..."
while ! qm agent $VM1_ID ping >/dev/null 2>&1; do
  sleep 5
done

echo -n "Polling Log Vault Cloud-Init status (This builds Docker and Squid)"
while ! qm guest exec $VM1_ID -- bash -c "cloud-init status" 2>/dev/null | grep -q "done"; do
  echo -n "."
  sleep 10
done
echo " [READY]"
echo "Log Vault is fully online. Proceeding with Cleanroom sequence."

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
  --net1 virtio,bridge=vmbr1,rate=$TARGET_RATE

qm set $VM2_ID \
  --ipconfig0 ip=dhcp \
  --ipconfig1 ip=$VM2_IP \
  --cicustom "user=$VM2_SNIPPET_PATH" \
  --tags "crs,experiment,fuzzer"

qm resize $VM2_ID scsi0 32G

echo "Configuring Cleanroom as Serial Sender..."
qm set $VM2_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=$SERIAL_PORT -device isa-serial,chardev=serial_log,index=1"

qm start $VM2_ID
echo "crs-cleanroom is booting!"

# ==========================================
# Strict Dependency Lock: Await Cleanroom
# ==========================================
echo "Waiting for Cleanroom QEMU Guest Agent to initialize..."
while ! qm agent $VM2_ID ping >/dev/null 2>&1; do
  sleep 5
done

echo -n "Polling Cleanroom Cloud-Init status (This installs Docker and clones repos)"
while ! qm guest exec $VM2_ID -- bash -c "cloud-init status" 2>/dev/null | grep -q "done"; do
  echo -n "."
  sleep 10
done
echo " [READY]"

# ==========================================
# Final State Enforcement: Apply Kernel Parameters
# ==========================================
echo "Rebooting Cleanroom to apply GRUB cgroup parameters..."
qm reboot $VM2_ID
sleep 15

echo "Waiting for Cleanroom to return online..."
while ! qm agent $VM2_ID ping >/dev/null 2>&1; do
  sleep 5
done

echo "[+] Cleanroom is fully online with strict Docker isolation."
echo "[+] Architecture provisioning complete."