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
    server cp1 {{ cp_node_1_ip }}:6443 check
    server cp2 {{ cp_node_2_ip }}:6443 check
    server cp3 {{ cp_node_3_ip }}:6443 check
```

> **Note:** Health checks are TCP-only (not HTTP). The k3s API server uses TLS, so plain HTTP health checks (`option httpchk`) would fail with `SSL_ERROR_SYSCALL`. TCP port checks reliably confirm the API server is listening.

### Phase 4: K3s Cluster Setup (Role: `k3s`)

**Applies to:** `control_plane` and `worker` groups

**What it does:**

1. **First control plane node** (`k3s-cp-1`):
   - Initializes the cluster with `--cluster-init` (embedded etcd for HA)
   - Does **not** use `--server` (that would cause a deadlock — it would try to reach itself through the LB before starting)
   - Adds `--tls-san {VIP}` so the TLS certificate includes the LB IP for nodes joining through it
   - **Disables default Flannel CNI** with `--flannel-backend=none` (Cilium is deployed in Phase 5)
   - **Disables built-in network policy controller** with `--disable-network-policy` (Cilium handles this)
   - Writes kubeconfig to `/root/.kube/config`

2. **Additional control plane nodes** (`k3s-cp-2`, `k3s-cp-3`):
   - Join the existing cluster via the load balancer (`--server https://{VIP}:6443`)
   - Use the same token from the first node
   - Must use **identical flags** as the first node (`--flannel-backend=none`, `--disable-network-policy`, `--tls-san`) — k3s validates config match across servers

3. **Worker nodes** (`k3s-worker-1`):
   - Join the cluster as workers using the `agent` subcommand (newer k3s versions don't accept `--worker` flag)
   - Point to the VIP for API server access

**K3s installation commands** (as per the plan):
```bash
# First control plane node (cluster init):
# NOTE: --server is NOT used here — the first node initializes itself.
# --tls-san ensures the LB IP is in the serving certificate.
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --cluster-init \
    --write-kubeconfig /root/.kube/config \
    --node-name k3s-cp-1 \
    --tls-san {VIP} \
    --flannel-backend=none \
    --disable-network-policy

# Additional control plane nodes (join via LB):
# NOTE: Must use identical flags (flannel-backend, disable-network-policy,
# tls-san) — k3s validates config match across all server nodes.
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - \
    --server https://{VIP}:6443 \
    --node-name k3s-cp-2 \
    --tls-san {VIP} \
    --flannel-backend=none \
    --disable-network-policy

# Worker nodes:
curl -sfL https://get.k3s.io | K3S_TOKEN=secret-token sh -s - agent \
    --server https://{VIP}:6443 \
    --node-name k3s-worker-1
```

### Phase 5: CNI and Storage (Roles: `cilium` + `storage`)

**Applies to:** first control plane node (`k3s-cp-1`)

#### cilium role
- Downloads and installs Cilium CLI from GitHub releases
- Installs the latest stable Cilium with eBPF support (no pinned version — avoids CLI/version compatibility issues)
- Configures via `--set` flags (not `--config` — that flag doesn't exist for `cilium install`):
  - `enable-endpoint-routes=true`
  - `enable-local-node-route=false`
  - `enable-host-reachable-services=true`
  - `enable-ipv4-masquerade=false`
  - `enable-bpf-tproxy=true`
- Waits for Cilium to become ready (polling up to 5 minutes)
- Automatically replaces kube-proxy (k3s was installed with `--disable-network-policy`)

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

### LB Not Reachable / SSL_ERROR_SYSCALL
```bash
# Check haproxy
ssh ubuntu@<LB_IP> sudo systemctl status haproxy
ssh ubuntu@<LB_IP> sudo haproxy -f /etc/haproxy/haproxy.cfg -c
```

---

## Known Issues & Fixes (from real deployment)

Below is a record of issues encountered during an actual Proxmox → K3s deployment and how they were resolved. These are baked into the playbooks but documented here for context.

### 1. First Node Bootstrap Deadlock (`--server` pointing to LB)

**Symptom:**
```
k3s[18771]: level=fatal msg="failed to validate token: failed to get CA certs:
Get \"https://192.168.1.160:6443/cacerts\": EOF"
```
HAProxy logs: `Layer4 connection problem, info: "Connection refused"`

**Root Cause:** The first control plane node (`--cluster-init`) used `--server https://<LB_IP>:6443`, making k3s try to bootstrap by connecting through the load balancer. But the LB pointed back to the same node which hadn't started yet — a deadlock.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Remove `--server` flag from the first node's install command
- Add `--tls-san {{ load_balancer_vip }}` so the TLS certificate includes the LB IP
- Additional nodes still use `--server https://<LB_IP>:6443` since the first node is already running

### 2. HAProxy HTTP Health Check Against TLS Endpoint

**Symptom:** HAProxy marks all control plane nodes as DOWN. `curl -k https://<LB_IP>:6443` returns `OpenSSL SSL_connect: SSL_ERROR_SYSCALL`.

**Root Cause:** HAProxy had `option httpchk GET /healthz` which sends a **plain HTTP** health check. The k3s API server speaks **HTTPS** (TLS). The health check fails → HAProxy marks backends as DOWN → no traffic forwarded.

**Fix (in `roles/haproxy/templates/haproxy.cfg.j2`):**
- Removed `option httpchk GET /healthz`
- HAProxy now uses a simple **TCP port check** (checks if port 6443 is open), which works fine with TLS endpoints

### 3. HAProxy Config Parse Error — Missing Trailing Newline

**Symptom:**
```
[ALERT] config : parsing [/etc/haproxy/haproxy.cfg:22]: Missing LF on last line,
file might have been truncated at position 40.
```

**Root Cause:** The Jinja2 template `haproxy.cfg.j2` did not end with a newline. HAProxy strictly requires a newline at end of file.

**Fix:** Added a trailing newline to the template file.

### 4. Wrong K3s Token Path

**Symptom:** `cat /etc/rancher/k3s/token: No such file or directory`

**Root Cause:** The k3s token is located at `/var/lib/rancher/k3s/server/token`, not `/etc/rancher/k3s/token`. The `/etc/rancher/k3s/` directory only contains the kubeconfig and does not have a `token` file.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Changed token read command from `cat /etc/rancher/k3s/token` to `cat /var/lib/rancher/k3s/server/token`
- Changed `creates:` guard on install tasks from `/etc/rancher/k3s/token` to `/usr/local/bin/k3s` (idempotency check based on binary presence)

### 5. Mismatched K3s Configuration on Additional Control Plane Nodes

**Symptom:**
```
failed to bootstrap cluster data: failed to validate server configuration:
critical configuration value mismatch between servers
```

**Root Cause:** The first node was installed with `--flannel-backend=none` and `--disable-network-policy`, but additional control plane nodes were missing these flags. k3s validates that all server nodes have matching critical configuration.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Added `--flannel-backend=none` and `--disable-network-policy` to additional control plane join commands

### 6. Cleanup of Broken K3s State

**Symptom:** After a failed install, re-running the playbook would not recover because partial state (binary, systemd service, data dirs) remained on the node.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Added cleanup blocks for **all** control plane nodes that check `systemctl cat` (does the service unit exist?) + `systemctl is-active` (is it running?). If the service exists but is not active, it stops, disables, wipes everything (binary, data dirs, systemd service), and reloads systemd.
- **Critical safety rule:** Wiping additional CP nodes is only safe when cp-1 was reinstalled fresh (new etcd cluster with no stale members). If cp-1 still has old etcd members, wiping cp-2/cp-3 would break quorum. The playbook handles the fresh-cluster case correctly.

### 7. `systemctl is-failed` Limitation

### 7. `systemctl is-failed` Limitation

**Issue:** `systemctl is-failed` only returns exit code 0 when the service is explicitly in a **failed** state (i.e., crashed). It does NOT return 0 for `inactive (dead)` (manually stopped) or other states. This caused the cleanup block to skip when k3s was stopped manually.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Changed from `systemctl is-failed` → `systemctl cat` (checks if the unit file exists) + `systemctl is-active` (checks if it's running)
- Cleanup now triggers on any non-active service, not just failed ones

### 8. Reboot Check & Health Verification

**Added to `roles/common/tasks/main.yml`:** At the end of the common role, the playbook now:
1. Checks if `/var/run/reboot-required` exists (created by kernel/package updates)
2. If reboot is needed: flushes handlers, reboots (waits up to 180s), reconnects, gathers fresh facts, and prints system health status
3. If no reboot needed: prints system health status directly
4. On failure: fails with a clear message

Health status includes: kernel version, uptime, CPU cores, memory, interface, and IP address.

### 9. Worker Node `--worker` Flag Not Recognized

**Symptom:**
```
k3s-worker-1 k3s[17457]: Incorrect Usage: flag provided but not defined: -worker
```

**Root Cause:** Newer versions of k3s (v1.36+) no longer accept `--worker` as a command-line flag. The install script expects the `agent` subcommand instead.

**Fix (in `roles/k3s/tasks/main.yml`):**
- Changed worker node install from `sh -s - --server ... --worker` to `sh -s - agent --server ...`
- The `agent` subcommand is the correct way to join as a worker in current k3s releases

### 10. Etcd Quorum Loss from Destructive Cleanup (Critical)

**Symptom:**
```
rafthttp/probing_status.go:68: prober detected unhealthy status
remote-peer-id: 73095abd836a3b58 rtt:0s
error: "dial tcp 192.168.1.151:2380: connect: connection refused"
```
Kubernetes API returns 500: `failed to get etcd MemberList: context deadline exceeded`. All control plane nodes show `NotReady`. `k3s etcd` subcommand does not exist (v1.36+).

**Root Cause:** The playbook previously wiped `/var/lib/rancher/k3s/` (including etcd data) on cp-2/cp-3 and ran `kubectl delete node` on cp-1. This destroyed the etcd cluster's membership. With 3 nodes and only 1 having valid state, etcd could not form quorum (needs 2/3) and stopped serving.

**Fix (in `roles/k3s/tasks/main.yml`):**
- **Never** wipe etcd data (`/var/lib/rancher/k3s/`) on additional CP nodes that are part of a running etcd cluster
- Removed the destructive cleanup block for cp-2/cp-3 — replaced with a safe restart-only approach
- Removed `k3s etcd member remove` task (subcommand doesn't exist in k3s v1.36+)
- Removed `kubectl delete node` step — deleting from Kubernetes API does not remove from etcd
- Changed cp-1 cleanup trigger from `systemctl is-failed` to `systemctl cat` + `systemctl is-active` to catch all non-running states (not just crashed)

**Full recovery documentation:** [`kubernetes/etcd-quorum-loss.md`](../etcd-quorum-loss.md)

### 11. Cilium Installation — `--version` and `--config` Flags

**Symptom 1:**
```
cilium install --version 1.15 ...
Error: Unable to install Cilium: cilium version unsupported 1.15.0
```

**Root Cause:** The Cilium CLI was too new to support v1.15. Pinning an old version causes incompatibility with the latest CLI tooling.

**Fix (in `roles/cilium/tasks/main.yml`):**
- Removed `--version 1.15` — uses the latest Cilium version compatible with the downloaded CLI

**Symptom 2:**
```
cilium install --config enable-endpoint-routes=true ...
unknown flag: --config
```

**Root Cause:** `--config` is not a valid flag for `cilium install`. The correct syntax uses `--set` for Helm values.

**Fix (in `roles/cilium/tasks/main.yml`):**
- Changed all `--config` to `--set=`

### 12. KUBECONFIG Not Set for Cilium Commands

**Symptom:** Cilium CLI commands fail because the `shell:` Ansible module doesn't use `root`'s environment. The kubeconfig is at `/root/.kube/config` but k3s sets this in the shell profile, which the `shell:` module doesn't source.

**Fix (in `roles/cilium/tasks/main.yml`):**
- Added `export KUBECONFIG=/root/.kube/config` before every `cilium` command

---

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