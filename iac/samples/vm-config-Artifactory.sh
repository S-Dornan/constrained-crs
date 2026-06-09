#!/usr/bin/env bash
# Run on Proxmox Host
# Provisions Artifactory, Backstage, and Gitea Runner

TEMPLATE_ID=9000
STORAGE="local-lvm"
SNIPPET_PATH="local:snippets/cloud-init.yaml"

# Define our VMs: "ID:Name:Backplane_IP"
VMS=(
  "201:artifactory:172.16.255.10"
  "202:backstage:172.16.255.11"
  "203:gitea-runner:172.16.255.12"
)

for VM_DATA in "${VMS[@]}"; do
  IFS=':' read -r VM_ID VM_NAME BACKPLANE_IP <<< "$VM_DATA"
  
  echo "Provisioning $VM_NAME ($VM_ID)..."
  
  # Clone the base template
  qm clone $TEMPLATE_ID $VM_ID --name $VM_NAME --full true --storage $STORAGE
  
  # Configure Hardware and Dual-NICs
  # net0 -> vmbr0 (WAN/LAN via DHCP)
  # net1 -> vmbr1 (Storage Backplane)
  qm set $VM_ID \
    --memory 4096 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --net1 virtio,bridge=vmbr1
    
  # Inject Cloud-Init Networking and User-Data Snippet
  # Note: ipconfig1 has NO gateway. This enforces the air-gapped backplane routing.
  qm set $VM_ID \
    --ipconfig0 ip=dhcp \
    --ipconfig1 ip=$BACKPLANE_IP/24 \
    --cicustom "user=$SNIPPET_PATH" \
    --tags "iac,infrastructure"
    
  # Resize the boot disk to 32GB
  qm resize $VM_ID scsi0 32G
  
  # Start the VM
  qm start $VM_ID
  
  echo "$VM_NAME is booting!"
done