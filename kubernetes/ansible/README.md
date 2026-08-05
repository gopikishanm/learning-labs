# Ansible Configuration for Kubernetes HA Cluster

This directory contains Ansible playbooks and roles to automate the configuration of a highly available (HA) K3s Kubernetes cluster on Proxmox.

## Architecture

The cluster consists of:
- **3 Control Plane nodes** (HA with embedded etcd via `--cluster-init`)
- **1+ Worker nodes** 
- **1 Load Balancer node** (HAProxy for API server load balancing)

## Directory Structure

```
ansible/
├── ansible.cfg                 # Ansible configuration
├── inventory/
│   └── hosts.ini               # Ansible inventory file
├── group_vars/
│   └── all.yml                 # Global variables
├── playbooks/
│   └── k8s-setup.yml           # Main playbook for full cluster setup
├── roles/
│   ├── common/                 # Phase 1-2: Host OS preparation
│   ├── haproxy/                # Phase 3: HAProxy load balancer
│   ├── k3s/                    # Phase 4: K3s installation & HA setup
│   ├── cilium/                 # Phase 5: Cilium CNI with eBPF
│   └── storage/                # Phase 5: OpenEBS storage
```

## Prerequisites

1. **Ansible installed** on the control machine (your laptop or a jump host):
   ```bash
   # On macOS
   brew install ansible
   
   # On Ubuntu/Debian
   sudo apt update && sudo apt install -y ansible
   ```

2. **SSH key-based access** to all target VMs (Proxmox VMs):
   ```bash
   ssh-copy-id ubuntu@<NODE_IP>
   ```

3. **Python 3** on all target nodes (Ubuntu 24.04 includes it by default).

---

## Configuration Steps

### Step 1: Update Inventory

Edit `inventory/hosts.ini` with the actual IP addresses of your Proxmox VMs:

```ini
[control_plane]
k3s-cp-1 ansible_host=192.168.1.101
k3s-cp-2 ansible_host=192.168.1.102
k3s-cp-3 ansible_host=192.168.1.103

[worker]
k3s-worker-1 ansible_host=192.168.1.201

[load_balancer]
k3s-lb-1 ansible_host=192.168.1.10
```

### Step 2: Update Group Variables

Edit `group_vars/all.yml` to set your environment-specific values:

```yaml
load_balancer_vip: "192.168.1.100"       # IP of the load balancer node
cp_node_1_ip: "192.168.1.101"           # Control plane node 1 IP
cp_node_2_ip: "192.168.1.102"           # Control plane node 2 IP
cp_node_3_ip: "192.168.1.103"           # Control plane node 3 IP
k3s_token: "your-secure-token"          # K3s cluster token
```

### Step 3: Verify Connectivity

```bash
ansible -i inventory/hosts.ini all -m ping
```

All nodes should return `"ping": "pong"`.

---

## Running the Setup

### Run All Phases (Full Cluster Setup)

```bash
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml
```

### Run Specific Phases

You can target specific phases using Ansible tags or by running only specific plays:

#### Phase 1-2: Host OS Preparation (all nodes)
```bash
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --tags common
```

#### Phase 3: Load Balancer Configuration
```bash
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --tags loadbalancer
```

#### Phase 4: K3s Cluster Setup
```bash
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --tags k3s
```

#### Phase 5: CNI and Storage
```bash
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --tags cni-storage
```

---

## Detailed Phase Breakdown

### Phase 1-2: Host OS Preparation (Role: `common`)

Applies to **all nodes** (control plane, worker, and load balancer).

**What it does:**
- Updates package cache
- Installs prerequisite packages (curl, gnupg2, ca-certificates, etc.)
- Loads kernel modules: `overlay`, `br_netfilter`
- Configures sysctl: `net.bridge.bridge-nf-call-iptables`, `ip_forward`, `vm.swappiness=0`
- Installs and configures containerd with systemd cgroup driver
- Configures systemd cgroup accounting

### Phase 3: Load Balancer Configuration (Role: `haproxy`)

**Applies to:** `load_balancer` group (k3s-lb-1)

The load balancer provides a single endpoint that all K3s nodes use to connect to the Kubernetes API server. It distributes traffic across the control plane nodes — if one control plane node goes down, HAProxy routes traffic to the remaining nodes.

> **Note:** Keepalived was originally included but has been removed. With only one load balancer VM, a VRRP-based virtual IP provides no high availability benefit — if the single LB node fails, Keepalived fails with it. HAProxy alone on the node's static IP is sufficient for this setup. If you add a second LB node in the future, reintroduce Keepalived to float a VIP between them.

#### haproxy role
- Installs HAProxy package
- Deploys `/etc/haproxy/haproxy.cfg` from template
- Configures TCP load balancing on port 6443 (Kubernetes API)
- Configures HTTP health checks on `/healthz` endpoint
- Balances across all 3 control plane nodes using round-robin

**Configuration template** (`roles/haproxy/templates/haproxy.cfg.j2`):
```cfg
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
    server cp1 {{ cp_node_1_ip }}:6443 check
   

### Phase 4: K3s Cluster Setup (Role: `k3s`)

**Applies to:** `control_plane` and `worker` groups

**What it does:**

1. **First control plane node** (`k3s-cp-1`):
   - Initializes the cluster with `--cluster-init` (embedded etcd for HA)
   - Uses `--server https://{VIP}:6443` to point to the load balancer
   - **Disables default Flannel CNI** with `--flannel-backend=none` (Cilium is deployed in Phase 5)
   - **Disables built-in network policy controller** with `--disable-network-policy` (Cilium handles this)
   - Writes kubeconfig to `/root/.kube/config`

2. **Additional control plane nodes** (`k3s-cp-2`, `k3s-cp-3`):
   - Join the existing cluster
   - Use the same token from the first node
   - Point to the VIP for API server access

3. **Worker nodes** (`k3s-worker-1`):
   - Join the cluster as workers
   - Use the `--worker` flag

**K3s installation commands** (as per the plan):
```bash
# First control plane node (cluster init):
# NOTE: --flannel-backend=none and --disable-network-policy disable
# K3s's default Flannel CNI so Cilium can be used instead (Phase 5).
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --cluster-init \
    --server https://{VIP}:6443 \
    --write-kubeconfig /root/.kube/config \
    --node-name k3s-cp-1 \
    --flannel-backend=none \
    --disable-network-policy

# Additional control plane nodes (join):
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{VIP}:6443 \
    --node-name k3s-cp-2

# Worker nodes:
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{VIP}:6443 \
    --node-name k3s-worker-1 \
    --worker
```

### Phase 5: CNI and Storage (Roles: `cilium` + `storage`)

**Applies to:** first control plane node (`k3s-cp-1`)

#### cilium role
- Downloads and installs Cilium CLI
- Installs Cilium v1.15 with eBPF support
- Configures: endpoint routes, host-reachable services, BPF tproxy

#### storage role
- Installs Helm
- Deploys OpenEBS via Helm
- Creates `openebs-local` StorageClass

---

## Verification

After running the full playbook, verify the cluster:

```bash
# SSH into any control plane node
ssh ubuntu@<CP_NODE_IP>

# Check nodes
kubectl get nodes -o wide

# Check all pods
kubectl get pods -A

# Check Cilium status
cilium status --wait

# Check storage classes
kubectl get sc
```

Expected output:
- **Nodes**: All 3 control plane nodes and worker node should be `Ready`
- **Pods**: CoreDNS, Cilium, and OpenEBS pods should be `Running`
- **StorageClass**: `openebs-local` should be available

---

## Troubleshooting

### SSH Connection Issues
```bash
# Test connectivity
ansible -i inventory/hosts.ini all -m ping -vvv

# Check SSH key
ssh -i ~/.ssh/id_rsa ubuntu@<NODE_IP>
```

### Playbook Hangs on K3s Installation
The first control plane node installation can take 1-2 minutes. The playbook waits with retries. If it times out:
```bash
# Check if k3s is running
ssh ubuntu@<CP1_IP> sudo systemctl status k3s

# Check logs
ssh ubuntu@<CP1_IP> sudo journalctl -u k3s -f
```

### VIP Not Reachable
```bash
# Check haproxy
ssh ubuntu@<LB_IP> sudo systemctl status haproxy
ssh ubuntu@<LB_IP> sudo haproxy -f /etc/haproxy/haproxy.cfg -c
```

### Running Specific Plays Individually

If you need to run only specific phases (e.g., after fixing an issue):

```bash
# Phase 3 only (load balancer)
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml \
    --limit load_balancer

# Phase 4 only (K3s cluster)
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml \
    --limit control_plane:worker

# Phase 5 only (CNI + storage)
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml \
    --limit control_plane[0] \
    --tags cni-storage
```

1. Fill in actual IP addresses in the inventory file
2. Run `ansible-playbook` to configure all nodes
3. Proceed with Phase 3: Load Balancer Configuration and HA setup

## Requirements

- Ansible installed on the control machine
- SSH access to all nodes with appropriate permissions