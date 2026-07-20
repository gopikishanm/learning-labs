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

# Check if we have the Ubuntu cloud image
if [ ! -f "ubuntu-24.04-server-cloudimg-amd64.img" ]; then
    log "Downloading Ubuntu 24.04 LTS Cloud Image..."
    wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img || error "Failed to download Ubuntu cloud image"
fi

# Configuration - These should be set based on your environment
PROXMOX_STORAGE="local-lvm"  # Adjust this to your storage location
VM_TEMPLATE_ID=9000         # Base template VM ID (will be reused)
BASE_VM_NAME="k3s-base-ubuntu2404"

# Display configuration
log "Configuration:"
echo "  Proxmox Storage: $PROXMOX_STORAGE"
echo "  Template VM ID: $VM_TEMPLATE_ID" 
echo "  Base VM Name: $BASE_VM_NAME"

# Verify Proxmox storage exists
log "Checking if Proxmox storage '$PROXMOX_STORAGE' is available..."
if ! qm list | grep -q "$PROXMOX_STORAGE"; then
    warn "Storage '$PROXMOX_STORAGE' might not be available. Proceeding anyway."
fi

# Import the image to Proxmox storage
log "Importing Ubuntu cloud image to Proxmox storage..."
qm importdisk 0 ubuntu-24.04-server-cloudimg-amd64.img "$PROXMOX_STORAGE" || error "Failed to import disk image"

# Create a base VM template
log "Creating base VM template..."
if qm list | grep -q "$VM_TEMPLATE_ID"; then
    warn "VM ID $VM_TEMPLATE_ID already exists. Reusing it."
else
    qm create "$VM_TEMPLATE_ID" --name "$BASE_VM_NAME" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0 || error "Failed to create VM template"
fi

# Set disk configuration
log "Setting up disk configuration..."
qm set "$VM_TEMPLATE_ID" --disk 0,ssd=1,size=20G || error "Failed to set disk configuration"

# Set serial and VGA settings
log "Setting up serial and VGA configurations..."
qm set "$VM_TEMPLATE_ID" --serial0 socket --vga serial0 || error "Failed to configure serial/VGA"

# Configure cloud-init for the base template
log "Configuring cloud-init settings..."
qm set "$VM_TEMPLATE_ID" --ipconfig0 ip=dhcp || error "Failed to configure IP settings"
qm set "$VM_TEMPLATE_ID" --ciuser ubuntu || error "Failed to configure cloud-init user"

# For security, you should provide your SSH key path here
SSH_KEY_PATH="/path/to/public/ssh/key"
if [ -f "$SSH_KEY_PATH" ]; then
    qm set "$VM_TEMPLATE_ID" --sshkeys "$SSH_KEY_PATH" || error "Failed to configure SSH keys"
    log "SSH keys configured from $SSH_KEY_PATH"
else
    warn "SSH key not found at $SSH_KEY_PATH. You'll need to set this up manually."
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
echo "  qm clone $VM_TEMPLATE_ID {CP_VM_ID_1} --name k3s-cp-1 --net0 virtio,bridge=vmbr0"
echo "  qm clone $VM_TEMPLATE_ID {CP_VM_ID_2} --name k3s-cp-2 --net0 virtio,bridge=vmbr0"
echo "  qm clone $VM_TEMPLATE_ID {CP_VM_ID_3} --name k3s-cp-3 --net0 virtio,bridge=vmbr0"
echo "  qm clone $VM_TEMPLATE_ID {WORKER_VM_ID_1} --name k3s-worker-1 --net0 virtio,bridge=vmbr0"
echo "  qm clone $VM_TEMPLATE_ID {LB_VM_ID_1} --name k3s-lb-1 --net0 virtio,bridge=vmbr0"

exit 0