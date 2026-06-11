#!/usr/bin/env bash
# Run on Proxmox Host
# Provisions the OSS-CRS Cleanroom and the Log Vault

TEMPLATE_ID=9001
STORAGE="local-lvm"
SNIPPET_PATH="local:snippets/cloud-init.yaml"
VM1_ID="301"
VM2_ID="302"

echo "[*] Staging Cloud-Init Snippet..."
mkdir -p /var/lib/vz/snippets
cp cloud-init.yaml /var/lib/vz/snippets/cloud-init.yaml

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

  # If we just booted the Vault, pause for 2 seconds to let the socket bind
  if [ "$VM_NAME" == "crs-log-vault" ]; then
    echo "Waiting for hypervisor socket to bind on port 9001..."
    sleep 2
  fi

done

echo "[+] Architecture provisioned successfully."