#!/usr/bin/env bash
# Run on Proxmox Host
# Provisions the OSS-CRS Cleanroom and the Log Vault

TEMPLATE_ID=9001
STORAGE="local-lvm"
SNIPPET_PATH="local:snippets/cloud-init.yaml"

# Define our VMs: "ID:Name:Backplane_IP"
VMS=(
  "201:crs-cleanroom:172.16.255.20"
  "202:crs-log-vault:172.16.255.21"
)

echo "[*] Initializing CRS Cleanroom Architecture..."

for VM_DATA in "${VMS[@]}"; do
  IFS=':' read -r VM_ID VM_NAME BACKPLANE_IP <<< "$VM_DATA"
  
  echo "Provisioning $VM_NAME ($VM_ID)..."
  
  # Clone the base template
  qm clone $TEMPLATE_ID $VM_ID --name $VM_NAME --full true --storage $STORAGE
  
  # Configure Hardware, Dual-NICs, and QEMU Guest Agent
  qm set $VM_ID \
    --memory 4096 \
    --cores 2 \
    --agent 1 \
    --net0 virtio,bridge=vmbr0 \
    --net1 virtio,bridge=vmbr1
    
  # Inject Cloud-Init Networking
  qm set $VM_ID \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=$BACKPLANE_IP/24 \
    --cicustom "user=$SNIPPET_PATH" \
    --tags "crs,experiment"
    
  # Resize the boot disk
  qm resize $VM_ID scsi0 32G
  
  # ==========================================
  # Cleanroom-Specific Hardware Configurations
  # ==========================================
  if [ "$VM_NAME" == "crs-cleanroom" ]; then
    echo "Attaching Virtual Serial Port to Cleanroom..."
    # Exposes /dev/ttyS0 inside the VM to a UNIX socket on the Proxmox host
    qm set $VM_ID --serial0 socket
  fi

  # Start the VM
  qm start $VM_ID
  echo "$VM_NAME is booting!"
done

echo "[+] Architecture provisioned successfully."