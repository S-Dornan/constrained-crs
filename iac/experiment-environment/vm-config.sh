#!/usr/bin/env bash
# Run on Proxmox Host
# Provisions the OSS-CRS Cleanroom and the Log Vault

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
# Clean Slate Safeguard (Idempotency)
# ==========================================
echo "[*] Checking for existing cleanroom instances..."
for TARGET_ID in "$VM1_ID" "$VM2_ID"; do
  if qm status "$TARGET_ID" >/dev/null 2>&1; then
    echo "[!] Found existing VM $TARGET_ID. Tearing down for a clean run..."
    qm stop "$TARGET_ID" >/dev/null 2>&1 || true
    sleep 2
    qm destroy "$TARGET_ID"
  fi
done

echo "[*] Staging Cloud-Init Snippet..."
mkdir -p /var/lib/vz/snippets
cp cloud-init-logging.yaml /var/lib/vz/snippets/cloud-init-logging.yaml
cp cloud-init-cleanroom.yaml /var/lib/vz/snippets/cloud-init-cleanroom.yaml

# Define our VMs in strict boot order: "ID:Name:Backplane_IP"
VMS=(
  "$VM1_ID:crs-log-vault:172.16.255.20"
  "$VM2_ID:crs-cleanroom:172.16.255.21"
)

echo "[*] Initializing CRS Cleanroom Architecture..."

for VM_DATA in "${VMS[@]}"; do
  IFS=':' read -r VM_ID VM_NAME BACKPLANE_IP <<< "$VM_DATA"
  
  echo "Provisioning $VM_NAME ($VM_ID)..."
  
  # Clone the base template
  qm clone $TEMPLATE_ID $VM_ID --name $VM_NAME --full true --storage $STORAGE
  
  # ==========================================
  # Role-Based Hardware Allocation
  # ==========================================
  if [ "$VM_NAME" == "crs-log-vault" ]; then
    echo "Applying static, lightweight footprint to Log Vault..."
    qm set $VM_ID \
      --memory 2048 \
      --cores 1 \
      --agent 1 \
      --net0 virtio,bridge=vmbr0 \
      --net1 virtio,bridge=vmbr1
  else
    echo "Applying experimental starvation profile to Cleanroom..."
    qm set $VM_ID \
      --memory $TARGET_RAM \
      --cores $TARGET_CORES \
      --agent 1 \
      --net0 virtio,bridge=vmbr0,rate=$TARGET_RATE \
      --net1 virtio,bridge=vmbr1
  fi

  # ==========================================
  # Route the Correct Cloud-Init File
  # ==========================================
  if [ "$VM_NAME" == "crs-log-vault" ]; then
    ACTIVE_SNIPPET=$VM1_SNIPPET_PATH
  else
    ACTIVE_SNIPPET=$VM2_SNIPPET_PATH
  fi
    
  # Inject Cloud-Init Networking
  qm set $VM_ID \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=$BACKPLANE_IP/24 \
    --cicustom "user=$ACTIVE_SNIPPET" \
    --tags "crs,experiment"
    
  # Resize the boot disk
  qm resize $VM_ID scsi0 32G
  
  # ==========================================
  # Native QEMU Serial Port Bridging
  # ==========================================
  
  if [ "$VM_NAME" == "crs-log-vault" ]; then
    echo "Configuring Log Vault as Serial Receiver..."
    qm set $VM_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=9001,server=on,wait=off -device isa-serial,chardev=serial_log"
  fi

  if [ "$VM_NAME" == "crs-cleanroom" ]; then
    echo "Configuring Cleanroom as Serial Sender..."
    qm set $VM_ID --args "-chardev socket,id=serial_log,host=127.0.0.1,port=9001 -device isa-serial,chardev=serial_log"
  fi

  # Start the VM dynamically based on the current loop iteration
  qm start $VM_ID
  echo "$VM_NAME is booting!"

  # If we just booted the Vault, wait deterministically for the socket to bind
  if [ "$VM_NAME" == "crs-log-vault" ]; then
    echo "Waiting for Log Vault hypervisor to bind port 9001..."
    
    # Loop continuously until the port shows up as LISTENing
    while ! ss -lptn | grep -q ":9001 "; do
      sleep 1
    done
    
    echo "Port 9001 is active. Proceeding with Cleanroom boot."
  fi

done

echo "[+] Architecture provisioned successfully."