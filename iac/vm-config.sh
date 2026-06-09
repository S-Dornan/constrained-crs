VMID=118 # Replace with the ID of your VM
USER_NAME="arcadmin" # Replace with a different username
USER_PASS="YourSecurePassword123!" # Replace with a stronger password

# Download the image
wget -nc https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Create the VM
qm create $VMID --name "Arc-enabled-AKS" --ostype l26 \
  --machine q35 --cpu host --cores 6 --memory 24576 \
  --agent 1 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0,firewall=1

# Import and attach the disk
qm disk import $VMID noble-server-cloudimg-amd64.img local-lvm
qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0
qm disk resize $VMID scsi0 64G

# Add the CloudInit drive and EFI disk
qm set $VMID --ide2 local-lvm:cloudinit
qm set $VMID --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=1

# Configure Cloud-Init User, Password, and Network (DHCP)
qm set $VMID --ciuser $USER_NAME
qm set $VMID --cipassword $USER_PASS
qm set $VMID --ipconfig0 ip=dhcp

# Pass through the GPU
qm set $VMID --hostpci0 0000:01:00.0,pcie=1,rombar=1
qm set $VMID --boot order=scsi0

# THE MAGIC: Tell Cloud-init to use your custom Snippet (Fixed to vendor=)
qm set $VMID --cicustom "vendor=local:snippets/arc-config.yaml"

# START THE VM!
qm start $VMID