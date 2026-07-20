#!/bin/bash

# Kubernetes HA Cluster - Phase 1 Setup Script
# This script automates the Proxmox base template creation for k3s cluster

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Kubernetes HA Cluster Setup - Phase 1${NC}"
echo -e "${BLUE}================================================${NC}"

# Check if required tools are installed
if ! command -v qm &> /dev/null; then
    error "Proxmox CLI 'qm' is not installed or not in PATH"
fi
if ! command -v pvesm &> /dev/null; then
    error "Proxmox CLI 'pvesm' is not installed or not in PATH"
fi

# Configuration - These should be set based on your environment
PROXMOX_STORAGE="local-lvm"  # Adjust this to your storage location
VM_TEMPLATE_ID=9000        # Base template VM ID (will be reused)
BASE_VM_NAME="k3s-base-ubuntu2404"
CLOUD_IMAGE="ubuntu-24.04-server-cloudimg-amd64.img"

# Check if the Ubuntu cloud image exists locally before downloading
if [ -f "$CLOUD_IMAGE" ]; then
    log "Ubuntu cloud image '$CLOUD_IMAGE' found locally. Skipping download."
else
    log "Downloading Ubuntu 24.04 LTS Cloud Image..."
    wget "https://cloud-images.ubuntu.com/releases/24.04/release/$CLOUD_IMAGE" || error "Failed to download Ubuntu cloud image"
fi

# Display configuration
log "Configuration:"
echo "  Proxmox Storage: $PROXMOX_STORAGE"
echo "  Template VM ID: $VM_TEMPLATE_ID" 
echo "  Base VM Name: $BASE_VM_NAME"
echo "  Cloud Image: $CLOUD_IMAGE"

# Verify Proxmox storage exists
log "Checking if Proxmox storage '$PROXMOX_STORAGE' is available..."
if ! pvesm status -content images | grep -q "$PROXMOX_STORAGE"; then
    warn "Storage '$PROXMOX_STORAGE' not found in 'pvesm status'. Proceeding anyway."
fi

# Create a base VM template first, then import the disk
log "Creating base VM template..."
if qm list 2>/dev/null | awk '{print $1}' | grep -q "^$VM_TEMPLATE_ID$"; then
    warn "VM ID $VM_TEMPLATE_ID already exists. Reusing it."
else
    qm create "$VM_TEMPLATE_ID" --name "$BASE_VM_NAME" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0 || error "Failed to create VM template"
fi

# Check if the VM already has a disk attached (e.g., scsi0)
EXISTING_DISK=$(qm config "$VM_TEMPLATE_ID" 2>/dev/null | grep -E '^scsi0:' | awk '{print $2}')
if [ -n "$EXISTING_DISK" ]; then
    log "VM $VM_TEMPLATE_ID already has disk '$EXISTING_DISK'. Skipping import and attach."
else
    # Check for any unused disks on the VM (from a previous import that wasn't attached)
    UNUSED_DISK=$(qm config "$VM_TEMPLATE_ID" 2>/dev/null | grep -E '^unused0:' | awk '{print $2}')
    if [ -n "$UNUSED_DISK" ]; then
        log "Found unused disk '$UNUSED_DISK'. Attaching it to VM..."
        qm set "$VM_TEMPLATE_ID" --scsihw virtio-scsi-pci --scsi0 "$UNUSED_DISK" || error "Failed to attach unused disk"
    else
        # Import the image to Proxmox storage (must be done after VM creation)
        log "Importing Ubuntu cloud image to Proxmox storage..."
        IMPORT_OUTPUT=$(qm importdisk "$VM_TEMPLATE_ID" "$CLOUD_IMAGE" "$PROXMOX_STORAGE" 2>&1)
        echo "$IMPORT_OUTPUT"

        # Extract the actual imported disk name from the output
        # Output format: "unused0: successfully imported disk 'local-lvm:vm-9000-disk-2'"
        IMPORTED_DISK=$(echo "$IMPORT_OUTPUT" | grep -oP "successfully imported disk '\K[^']+")
        if [ -z "$IMPORTED_DISK" ]; then
            error "Failed to determine imported disk name from import output"
        fi

        log "Attaching imported disk '$IMPORTED_DISK' to VM..."
        qm set "$VM_TEMPLATE_ID" --scsihw virtio-scsi-pci --scsi0 "$IMPORTED_DISK" || error "Failed to attach imported disk"
    fi
fi

# Resize the disk to the desired size
log "Resizing disk to 20G..."
qm disk resize "$VM_TEMPLATE_ID" scsi0 20G || warn "Disk resize failed. You may need to resize manually."

# Set boot order to boot from disk first (prevents PXE/network boot)
log "Setting boot order to disk first..."
qm set "$VM_TEMPLATE_ID" --boot order=scsi0 || error "Failed to set boot order"

# Set serial and VGA settings
log "Setting up serial and VGA configurations..."
qm set "$VM_TEMPLATE_ID" --serial0 socket --vga serial0 || error "Failed to configure serial/VGA"

# Configure cloud-init for the base template
log "Configuring cloud-init settings..."
# NOTE: Do NOT set --ipconfig0 on the template. Clones inherit this setting
# and will pick up a random DHCP IP before the static IP override takes effect.
# Instead, set static IPs on each clone individually using qm set.
qm set "$VM_TEMPLATE_ID" --ciuser ubuntu || error "Failed to configure cloud-init user"
qm set "$VM_TEMPLATE_ID" --cipassword "ubuntu" || error "Failed to configure cloud-init password"

# Use the generated SSH key for VM access
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY_PATH="$SCRIPT_DIR/ssh-keys/k3s-cluster.pub"
if [ -f "$SSH_KEY_PATH" ]; then
    qm set "$VM_TEMPLATE_ID" --sshkeys "$SSH_KEY_PATH" || error "Failed to configure SSH keys"
    log "SSH keys configured from $SSH_KEY_PATH"
else
    error "SSH key not found at $SSH_KEY_PATH. Run 'ssh-keygen' first or check the path."
fi

# Set additional network and domain settings
log "Setting search domain and nameserver..."
qm set "$VM_TEMPLATE_ID" --searchdomain "localdomain" || error "Failed to configure search domain"
qm set "$VM_TEMPLATE_ID" --nameserver "8.8.8.8" || error "Failed to configure nameserver"

# Convert to template
log "Converting VM to template..."
qm template "$VM_TEMPLATE_ID" || error "Failed to convert to template"

log "Phase 1 completed successfully!"
echo ""
echo -e "${GREEN}Next steps:${NC}"
echo "1. Configure your node requirements (IP addresses, CPU/Memory specs)"
echo "2. Create VMs from the template using appropriate IDs"
echo "3. Proceed to Phase 2: Host OS Preparation"

# Provide instructions for next steps
echo ""
echo -e "${BLUE}Instructions:${NC}"
echo "To create VMs from the template, use commands like:"
echo ""
echo "IMPORTANT:"
echo "  - The template does NOT have --ipconfig0 set (no DHCP)"
echo "  - You MUST set a static IP on each clone before first boot"
echo "  - Login with user 'ubuntu' using either:"
echo "    a) SSH key: ssh -i ssh-keys/k3s-cluster ubuntu@<VM_IP>"
echo "    b) Password: ubuntu (set via --cipassword during template creation)"
echo ""
echo "--- Control Plane Nodes ---"
echo "qm clone $VM_TEMPLATE_ID {CP_VM_ID_1} --name k3s-cp-1"
echo "qm set {CP_VM_ID_1} --ipconfig0 ip={CP_NODE_1_IP}/24,gw={GATEWAY_IP}"
echo "qm start {CP_VM_ID_1}"
echo ""
echo "qm clone $VM_TEMPLATE_ID {CP_VM_ID_2} --name k3s-cp-2"
echo "qm set {CP_VM_ID_2} --ipconfig0 ip={CP_NODE_2_IP}/24,gw={GATEWAY_IP}"
echo "qm start {CP_VM_ID_2}"
echo ""
echo "qm clone $VM_TEMPLATE_ID {CP_VM_ID_3} --name k3s-cp-3"
echo "qm set {CP_VM_ID_3} --ipconfig0 ip={CP_NODE_3_IP}/24,gw={GATEWAY_IP}"
echo "qm start {CP_VM_ID_3}"
echo ""
echo "--- Worker Node ---"
echo "qm clone $VM_TEMPLATE_ID {WORKER_VM_ID_1} --name k3s-worker-1"
echo "qm set {WORKER_VM_ID_1} --ipconfig0 ip={WORKER_NODE_IP}/24,gw={GATEWAY_IP}"
echo "qm start {WORKER_VM_ID_1}"
echo ""
echo "--- Load Balancer Node ---"
echo "qm clone $VM_TEMPLATE_ID {LB_VM_ID_1} --name k3s-lb-1"
echo "qm set {LB_VM_ID_1} --ipconfig0 ip={LB_NODE_IP}/24,gw={GATEWAY_IP}"
echo "qm start {LB_VM_ID_1}"

exit 0