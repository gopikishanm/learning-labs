# Kubernetes HA Cluster Implementation Plan

This document outlines the steps to create a highly available Kubernetes cluster using k3s on Proxmox VE.

## Node Requirements

Before proceeding, please specify the following details for each node:

### Control Plane Nodes (3)
- IP addresses to be assigned to each control plane node
- CPU cores and memory (RAM) requirements per node  
- Disk space requirements per node

### Worker Nodes (1)
- IP addresses to be assigned to the worker node
- CPU cores and memory (RAM) requirements per node  
- Disk space requirements per node

### Load Balancer Nodes (1)
- IP addresses to be assigned to the load balancer node
- CPU cores and memory (RAM) requirements per node  
- Disk space requirements per node

These specifications will be used to configure the Proxmox templates and VMs appropriately.

## Phase 1: Proxmox Base Template Creation

### 1. Download Ubuntu 24.04 LTS Cloud Image
```bash
# Download the Ubuntu 24.04 cloud-init image
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
```

### 2. Create Base Template in Proxmox
```bash
# Import the image to Proxmox storage (assuming local-lvm)
qm importdisk 0 ubuntu-24.04-server-cloudimg-amd64.img local-lvm

# Create a base VM template
# Based on node requirements, adjust memory and CPU cores accordingly:
# For example, if each control plane node requires 4GB RAM and 2 CPUs:
qm create 9000 --name k3s-base-ubuntu2404 --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0
qm set 9000 --disk 0,ssd=1,size=20G
qm set 9000 --serial0 socket --vga serial0

# Configure cloud-init for the base template
qm set 9000 --ipconfig0 ip=dhcp
qm set 9000 --ciuser ubuntu
qm set 9000 --sshkeys "/path/to/public/ssh/key"
qm set 9000 --searchdomain "localdomain"
qm set 9000 --nameserver "8.8.8.8"

# Convert to template
qm template 9000
```

### 3. Create VMs from Template
```bash
# Create Control Plane nodes (3)
# Based on assigned IP addresses and node requirements:
# Using descriptive VM IDs for better organization
qm clone 9000 {CP_VM_ID_1} --name k3s-cp-1 --net0 virtio,bridge=vmbr0
qm clone 9000 {CP_VM_ID_2} --name k3s-cp-2 --net0 virtio,bridge=vmbr0
qm clone 9000 {CP_VM_ID_3} --name k3s-cp-3 --net0 virtio,bridge=vmbr0

# Create Worker node (1)
# Based on assigned IP addresses and node requirements:
qm clone 9000 {WORKER_VM_ID_1} --name k3s-worker-1 --net0 virtio,bridge=vmbr0

# Create Load Balancer node (1)
# Based on assigned IP addresses and node requirements:
qm clone 9000 {LB_VM_ID_1} --name k3s-lb-1 --net0 virtio,bridge=vmbr0
```

## Phase 2: Host OS Preparation

### 1. Configure Kernel Modules and Settings
```bash
# Create /etc/modules-load.d/k8s.conf to load required kernel modules
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

# Load modules immediately
modprobe overlay
modprobe br_netfilter

# Configure sysctl settings for Kubernetes networking
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.swappiness=0
EOF

# Apply sysctl settings
sysctl --system
```

### 2. Install Required Packages and Configure Container Runtime

```bash
# Update package list and install required packages
apt update && apt install -y \
    curl \
    gnupg2 \
    software-properties-common \
    ca-certificates \
    apt-transport-https

# Install containerd with systemd cgroup driver
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update && apt install -y containerd

# Configure containerd to use systemd cgroup driver
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Edit the config file to set systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
```

### 3. Configure systemd for containerd

```bash
# Restart and enable containerd service
systemctl restart containerd
systemctl enable containerd

# Configure systemd to handle cgroup management properly
cat > /etc/systemd/system.conf.d/10-cgroups.conf << EOF
[Manager]
DefaultCPUAccounting=yes
DefaultIOAccounting=yes
DefaultMemoryAccounting=yes
EOF

# Reload systemd configuration
systemctl daemon-reload
```

## Phase 3: Load Balancer Configuration

### 1. Configure HAProxy and Keepalived for VIP

```bash
# Install required packages on load balancer VMs
apt update && apt install -y haproxy keepalived

# Configure HAProxy (edit /etc/haproxy/haproxy.cfg)
# Based on assigned IP addresses for control plane nodes:
cat > /etc/haproxy/haproxy.cfg << EOF
global
    daemon
    maxconn 4096

defaults
    mode tcp
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-servers

backend k8s-api-servers
    mode tcp
    balance roundrobin
    option httpchk GET /healthz
    server cp1 {CP_NODE_1_IP}:6443 check
    server cp2 {CP_NODE_2_IP}:6443 check
    server cp3 {CP_NODE_3_IP}:6443 check
EOF

# Configure Keepalived (edit /etc/keepalived/keepalived.conf)
# Based on assigned VIP and load balancer node IP:
cat > /etc/keepalived/keepalived.conf << EOF
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k3scluster
    }
    virtual_ipaddress {
        {LOAD_BALANCER_VIP}/24
    }
}
EOF

# Enable and start services
systemctl enable haproxy keepalived
systemctl start haproxy keepalived
```

## Phase 4: K3s Cluster Setup

### 1. Initialize Control Plane Nodes with HA Configuration

```bash
# On the first control plane node ({CP_NODE_1_IP})
# Initialize the cluster with HA configuration
# NOTE: --flannel-backend=none and --disable-network-policy are required
# because we deploy Cilium as the CNI in Phase 5. Without these, K3s's
# default Flannel CNI will conflict with Cilium.
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --cluster-init \
    --server https://{LOAD_BALANCER_VIP}:6443 \
    --write-kubeconfig /root/.kube/config \
    --node-name k3s-cp-1 \
    --flannel-backend=none \
    --disable-network-policy

# Get the join token for other nodes
cat /etc/rancher/k3s/token
```

### 2. Join Additional Control Plane Nodes

```bash
# On second and third control plane nodes ({CP_NODE_2_IP}, {CP_NODE_3_IP})
# Join with the same token and server address
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{LOAD_BALANCER_VIP}:6443 \
    --node-name k3s-cp-2

curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{LOAD_BALANCER_VIP}:6443 \
    --node-name k3s-cp-3
```

### 3. Join Worker Nodes

```bash
# On worker node ({WORKER_NODE_IP})
# Join with the same token and server address
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{LOAD_BALANCER_VIP}:6443 \
    --node-name k3s-worker-1 \
    --worker
```

## Phase 5: CNI and Storage Deployment

### 1. Deploy Cilium with eBPF Support

```bash
# Install Cilium CLI (on any node)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz

# Extract and install
tar xzvf cilium-linux-amd64.tar.gz
sudo mv cilium /usr/local/bin/

# Deploy Cilium with eBPF support (run on any node)
cilium install --version 1.15 \
    --config enable-endpoint-routes=true \
    --config enable-local-node-route=false \
    --config enable-host-reachable-services=true \
    --config enable-ipv4-masquerade=false \
    --config enable-bpf-tproxy=true

# Verify installation
cilium status --wait
```

### 2. Deploy Storage Solution (OpenEBS or Longhorn)

#### Option A: OpenEBS Installation

```bash
# Install OpenEBS using Helm (run on any node)
helm repo add openebs https://openebs.github.io/charts
helm repo update

# Install OpenEBS with default configuration
helm install openebs openebs/openebs \
    --namespace openebs \
    --create-namespace \
    --set localprovisioner.storagePath=/var/openebs/local

# Create StorageClass for OpenEBS
cat > /tmp/openebs-storageclass.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-local
provisioner: local.csi.openebs.io
volumeBindingMode: WaitForFirstConsumer
EOF

kubectl apply -f /tmp/openebs-storageclass.yaml
```

#### Option B: Longhorn Installation

```bash
# Install Longhorn using Helm (run on any node)
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn with default configuration
helm install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --set defaultSettings.backupTarget="nfs://backup-server:/backup"

# Create StorageClass for Longhorn
cat > /tmp/longhorn-storageclass.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "2880"
EOF

kubectl apply -f /tmp/longhorn-storageclass.yaml
```

### 3. Verify Cluster Components

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Verify Cilium is running properly
cilium status --wait

# Check storage classes are available
kubectl get sc
```