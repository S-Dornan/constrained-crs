#!/usr/bin/env bash
# Run on Proxmox Host to create the base Cloud-Init Template

TEMPLATE_ID=9001
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_NAME="noble-server-cloudimg-amd64.img"
STORAGE="local-lvm" # Adjust this if your VM storage is named differently

echo "--- Starting Template Creation for ID $TEMPLATE_ID ---"

# 1. Download the latest cloud image if not present
if [ ! -f "$IMAGE_NAME" ]; then
    echo "Downloading Ubuntu Cloud Image..."
    wget -q --show-progress "$IMAGE_URL"
fi

# 2. Destroy existing template if it exists (to allow for 'run-many' updates)
if qm status $TEMPLATE_ID >/dev/null 2>&1; then
    echo "Cleaning up old template $TEMPLATE_ID..."
    qm destroy $TEMPLATE_ID
fi

# 3. Create the VM structure
echo "Creating VM $TEMPLATE_ID..."
qm create $TEMPLATE_ID --name "ubuntu-2404-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0

# 4. Import the disk image into Proxmox storage
echo "Importing disk to $STORAGE..."
qm importdisk $TEMPLATE_ID "$IMAGE_NAME" "$STORAGE"

# 5. Configure the VM to use the imported disk
# Note: 'qm importdisk' creates a volume name like 'vm-9000-disk-0'
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 "$STORAGE:vm-$TEMPLATE_ID-disk-0"

# 6. Add the Cloud-Init drive
qm set $TEMPLATE_ID --ide2 "$STORAGE:cloudinit"

# 7. Configure boot and serial console (Cloud-Init needs the serial for some logs)
qm set $TEMPLATE_ID --boot c --bootdisk scsi0 --serial0 socket --vga serial0

# 8. Convert to a template
echo "Converting to Proxmox Template..."
qm template $TEMPLATE_ID

echo "--- Template $TEMPLATE_ID is ready for cloning! ---"