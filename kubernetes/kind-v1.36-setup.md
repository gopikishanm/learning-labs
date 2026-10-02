# Kubernetes v1.36 Cluster with kind (1 Control Plane + 3 Workers)

This guide sets up a 4-node Kubernetes **v1.36** cluster on macOS using **kind**
(Kubernetes in Docker), sized to fit within a **~20 GB** memory budget.

| Resource | Value |
|----------|-------|
| Host OS | macOS (Apple Silicon) |
| Container runtime | Docker Desktop |
| Kubernetes version | v1.36.4 |
| Nodes | 1 control-plane + 3 workers |
| Memory budget | ~20 GB (Docker Desktop VM) |

> **Key concept:** kind nodes are Docker containers. All four nodes share the
> Docker Desktop VM's memory — the 20 GB is a *shared budget*, not per-node
> capacity. The config therefore uses modest kubelet reservations so the
> scheduler behaves realistically without overcommitting the pool.

---

## Prerequisites

### 1. Docker Desktop memory

kind runs every node as a container inside the Docker Desktop VM. The default
allocation (often 8 GB) is **not enough** for 4 nodes.

Set **Docker Desktop → Settings → Resources**:

| Setting | Recommended |
|---------|-------------|
| Memory | **18 GB** (leave ~2 GB for macOS) |
| CPUs | 4–6 |
| Disk | ≥ 60 GB |

Verify:

```sh
docker info --format '{{.MemTotal}}' | awk '{printf "Docker VM memory: %.1f GB\n", $1/1024/1024/1024}'
```

You should see roughly `18.0 GB`.

### 2. kind ≥ v0.32.0

Kubernetes 1.36+ uses the **kubeadm v1beta4** config format. kind added support
for this in **v0.32.0**; older versions (e.g. v0.27.0) will fail to create a
1.36 cluster. Use **v0.33.0** (ships Kubernetes 1.36.4).

```sh
# Apple Silicon (arm64)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-darwin-arm64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

kind version
```

> **Homebrew PATH gotcha:** if you installed kind via Homebrew, `/opt/homebrew/bin`
> usually precedes `/usr/local/bin` in `PATH`, so a binary dropped in
> `/usr/local/bin` is ignored. Upgrade the Homebrew copy instead:
>
> ```sh
> brew upgrade kind
> hash -r
> kind version
> ```
>
> Check which binary wins with `which -a kind`.

### 3. kubectl

```sh
brew install kubectl
kubectl version --client
```

---

## Cluster configuration

The cluster layout is defined in [`kind-v1.36-cluster.yaml`](./kind-v1.36-cluster.yaml):

- **1 control-plane** node (runs the API server, etcd, scheduler, controller-manager)
- **3 worker** nodes
- Pinned node image `kindest/node:v1.36.4`
- kubeadm **v1beta4** patches setting `system-reserved` and `eviction-hard`
- Host port mappings `80 → 8080` and `443 → 8443` on the control plane

### Why the reservations are modest

The existing `kind-kserve_day2.md` config reserves `3Gi`/`10Gi`/`3Gi` across
nodes. That works when each node maps to a separate VM, but here all nodes share
one Docker VM — those numbers would overcommit the pool. This config instead
reserves:

| Node | system-reserved | eviction-hard |
|------|-----------------|---------------|
| control-plane | `cpu=500m,memory=1Gi` | `memory.available<256Mi` |
| worker ×3 | `cpu=250m,memory=512Mi` | `memory.available<256Mi` |

This keeps the scheduler honest while leaving headroom for real workloads.

---

## Create the cluster

```sh
kind create cluster --name k8s-136 --config kubernetes/kind-v1.36-cluster.yaml
```

Output:

```text
Creating cluster "k8s-136" ...
 ✓ Ensuring node image (kindest/node:v1.36.4) 🖼️
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-k8s-136"
You can now use your cluster with:

kubectl cluster-info --context kind-k8s-136
```

---

## Verify

```sh
kubectl get nodes -o wide
```

```text
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
k8s-136-control-plane   Ready    control-plane   84s   v1.36.4   172.18.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker          Ready    <none>          69s   v1.36.4   172.18.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker2         Ready    <none>          69s   v1.36.4   172.18.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker3         Ready    <none>          69s   v1.36.4   172.18.0.5    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
```

Check system pods:

```sh
kubectl get pods -A
```

```text
NAMESPACE            NAME                                            READY   STATUS    RESTARTS   AGE
kube-system          coredns-589f44dc88-5qfz9                        1/1     Running   0          73s
kube-system          coredns-589f44dc88-vh6gb                        1/1     Running   0          73s
kube-system          etcd-k8s-136-control-plane                      1/1     Running   0          82s
kube-system          kindnet-68r66                                   1/1     Running   0          69s
kube-system          kindnet-brgfc                                   1/1     Running   0          69s
kube-system          kindnet-ddbz2                                   1/1     Running   0          69s
kube-system          kindnet-vtk24                                   1/1     Running   0          74s
kube-system          kube-apiserver-k8s-136-control-plane            1/1     Running   0          82s
kube-system          kube-controller-manager-k8s-136-control-plane   1/1     Running   0          81s
kube-system          kube-proxy-7llxk                                1/1     Running   0          69s
kube-system          kube-proxy-94tbk                                1/1     Running   0          69s
kube-system          kube-proxy-j7r6h                                1/1     Running   0          69s
kube-system          kube-proxy-trfbw                                1/1     Running   0          74s
kube-system          kube-scheduler-k8s-136-control-plane            1/1     Running   0          82s
local-path-storage   local-path-provisioner-56c4685b7c-qr4sf         1/1     Running   0          73s
```

Confirm the reservations took effect (look at `Allocatable`):

```sh
kubectl describe node k8s-136-worker | grep -A6 Allocatable
```

```text
Allocatable:
  cpu:                9750m
  ephemeral-storage:  90774610180
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  hugepages-32Mi:     0
  hugepages-64Ki:     0
```

Watch memory headroom:

```sh
docker stats --no-stream
```

### Smoke test

```sh
kubectl create deployment nginx --image=nginx --replicas=3
kubectl get pods -o wide
```

All three pods should reach `Running` and spread across the workers.

---

## Teardown

```sh
kind delete cluster --name k8s-136
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kind create` fails with kubeadm config errors | kind too old for v1beta4 | Upgrade kind to ≥ v0.32.0 |
| Nodes stuck `NotReady` / pods `OOMKilled` | Docker VM memory too low | Raise Docker Desktop memory to ~18 GB |
| `kind load` fails with new node images | kind < v0.27.0 | Upgrade kind |
| Worker nodes never join | Insufficient memory for 4 nodes | Reduce to 2 workers or raise memory |
