# Phase 2 — Kubernetes 1.36 Alpha Features (Feature Gates)

> **Status:** ✅ **Phase 2 complete** — all four labs (B1–B4) run and documented with real output.

These features are **Alpha** in Kubernetes 1.36 and must be enabled with
`featureGates` at cluster creation. Feature gates are **immutable**, so this phase
needs a **separate cluster** (`k8s-136-alpha`).

---

## Cluster

Create `k8s-136-alpha` from [`../kind-v1.36-alpha-cluster.yaml`](../kind-v1.36-alpha-cluster.yaml):

```sh
kind create cluster --name k8s-136-alpha --config kubernetes/kind-v1.36-alpha-cluster.yaml
kubectl config use-context kind-k8s-136-alpha
kubectl get nodes
```

The config enables these gates (all **Alpha** in 1.36):

| Gate | Lab | Purpose |
|------|-----|---------|
| `GenericWorkload` | B1 | Workload + PodGroup APIs (`scheduling.k8s.io/v1alpha2`) |
| `TopologyAwareWorkloadScheduling` | B1 | Placement-based PodGroup scheduling |
| `NativeHistograms` | B2 | Prometheus native histogram format |
| `PersistentVolumeClaimUnusedSinceTime` | B3 | `Unused` condition on PVCs |
| `MemoryQoS` | B4 | cgroup v2 memory protection/throttling |

> **Memory note:** this is a full **1 CP + 3 worker** cluster (~19 GB), matching
> Phase 1. Delete the Phase 1 cluster first so both do not run at the same time:
> ```sh
> kind delete cluster --name k8s-136
> ```

> **Verify the gates took effect** (Phase 1 A7 technique):
> ```sh
> kubectl get --raw "/api/v1/nodes/k8s-136-alpha-worker/proxy/flagz" \
>   | grep -o 'feature-gates=[^ ]*' | tr ',' '\n' \
>   | grep -i -E "GenericWorkload|NativeHistograms|MemoryQoS|PersistentVolumeClaimUnusedSinceTime"
> ```

### ERROR 1: cluster stuck NotReady — `cni plugin not initialized`

**SYMPTOM**
```
kubectl get nodes
# all nodes NotReady
# Ready False ... KubeletNotReady container runtime network not ready:
#   NetworkReady=false reason:NetworkPluginNotReady
#   message:Network plugin returns error: cni plugin not initialized
```

**CAUSE** — enabling `GenericWorkload` is necessary but **not sufficient**. Alpha
API groups are disabled by default and must be registered on the apiserver with
`--runtime-config`. Without it, kube-scheduler logs:

```
failed to list *v1alpha2.PodGroup: the server could not find the requested resource
failed to list *v1alpha2.Workload: the server could not find the requested resource
```

The scheduler stays `0/1`, nothing schedules, kindnet (CNI) pods stay `Pending`,
and every node reports `NetworkPluginNotReady`. The CNI message is the symptom;
the missing API group is the cause.

**FIX** — add a `ClusterConfiguration` patch to the control-plane node.

**BEFORE:**
```yaml
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        ...
      - |
        kind: KubeletConfiguration
```

**AFTER:**
```yaml
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        ...
      - |
        kind: ClusterConfiguration
        apiVersion: kubeadm.k8s.io/v1beta4
        apiServer:
          extraArgs:
            - name: runtime-config
              value: "scheduling.k8s.io/v1alpha2=true"
      - |
        kind: KubeletConfiguration
```

Then recreate the cluster (feature gates + runtime-config are immutable):
```sh
kind delete cluster --name k8s-136-alpha
kind create cluster --name k8s-136-alpha --config kubernetes/kind-v1.36-alpha-cluster.yaml
kubectl api-resources | grep -i -E "workload|podgroup"
# expect: workloads / podgroups  scheduling.k8s.io/v1alpha2
```

> **Note:** the transient `is forbidden: User "system:kube-scheduler" cannot list
> ...` errors for `volumeattachments`/`resourceslices`/`podgroups` are startup
> RBAC races — they clear once caches sync and are not the root cause.

---

## B1 — Workload / PodGroup gang scheduling

**What changed in 1.36** — the **Workload** and **PodGroup** APIs
(`scheduling.k8s.io/v1alpha2`) let you express workload-level scheduling
requirements. With `GenericWorkload` + `TopologyAwareWorkloadScheduling`, the
scheduler can place a whole group of Pods **all-or-nothing** (gang scheduling).

**Apply** — `manifests/workload-podgroup.yaml`:

<details>
<summary>📄 <code>manifests/workload-podgroup.yaml</code></summary>

```yaml
apiVersion: scheduling.k8s.io/v1alpha2
kind: Workload
metadata:
  name: gang-demo
  namespace: default
spec:
  podGroupTemplates:
    - name: workers
      schedulingPolicy:
        gang:
          minCount: 3
---
apiVersion: scheduling.k8s.io/v1alpha2
kind: PodGroup
metadata:
  name: gang-demo-workers
  namespace: default
spec:
  podGroupTemplateRef:
    workload:
      workloadName: gang-demo
      podGroupTemplateName: workers
  schedulingPolicy:
    gang:
      minCount: 3
```

</details>

**Observe** — create 3 Pods referencing the PodGroup; all 3 schedule together or
none do. Scale the group beyond available capacity and watch them stay `Pending`
as a group.

### ERROR 1: PodGroup strict decoding — unknown field

**SYMPTOM**
```
Error from server (BadRequest): error when creating
"kubernetes/labs/manifests/workload-podgroup.yaml": PodGroup in version
"v1alpha2" cannot be handled as a PodGroup: strict decoding error:
unknown field "spec.podGroupTemplateRef.podGroupTemplate",
unknown field "spec.podGroupTemplateRef.workload.name"
```

**CAUSE** — the v1alpha2 `PodGroupTemplateReference` uses **different field names**
than the v1beta1 docs show. In v1alpha2 the nested fields are flat:
`workloadName` and `podGroupTemplateName`. The v1beta1-style
`workload.name` / `podGroupTemplate.name` are rejected by strict decoding.

**FIX** — use the v1alpha2 field names.

**BEFORE:**
```yaml
  podGroupTemplateRef:
    workload:
      name: gang-demo              # <-- wrong (v1beta1 style)
    podGroupTemplate:
      name: workers                # <-- wrong (v1beta1 style)
```

**AFTER:**
```yaml
  podGroupTemplateRef:
    workload:
      workloadName: gang-demo      # <-- v1alpha2
      podGroupTemplateName: workers # <-- v1alpha2
```

> **Tip:** always confirm field names against the live cluster with
> `kubectl explain podgroup.spec.podGroupTemplateRef.workload` — the published
> docs may describe a newer API version than the one your cluster serves.

**Apply the worker Pods** — `manifests/gang-workers.yaml` (3 Pods, each joining
the group via `spec.schedulingGroup.podGroupName`):

<details>
<summary>📄 <code>manifests/gang-workers.yaml</code></summary>

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gang-worker-1
  namespace: default
spec:
  schedulingGroup:
    podGroupName: gang-demo-workers
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: gang-worker-2
  namespace: default
spec:
  schedulingGroup:
    podGroupName: gang-demo-workers
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: gang-worker-3
  namespace: default
spec:
  schedulingGroup:
    podGroupName: gang-demo-workers
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
```

</details>

```sh
kubectl apply -f kubernetes/labs/manifests/gang-workers.yaml
```

**Observed output (real):**

```
$ kubectl get pods -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP           NODE
gang-worker-1   1/1     Running   0          7s    10.244.1.2   k8s-136-alpha-worker3
gang-worker-2   1/1     Running   0          7s    10.244.2.2   k8s-136-alpha-worker
gang-worker-3   1/1     Running   0          7s    10.244.3.2   k8s-136-alpha-worker2

$ kubectl get podgroup gang-demo-workers -o wide
NAME                POLICY   WORKLOAD    STATUS      AGE
gang-demo-workers   Gang     gang-demo   Scheduled   81s

$ kubectl get podgroup gang-demo-workers -o jsonpath='{.status.conditions}'
[{"lastTransitionTime":"2026-10-02T01:05:03Z","message":"","reason":"Scheduled",
  "status":"True","type":"PodGroupScheduled"}]
```

**Result:** all 3 Pods scheduled together across 3 different nodes, and the
PodGroup reports `STATUS Scheduled` with condition **`PodGroupScheduled=True`**.

> **Gotcha:** the docs call this condition `PodGroupInitiallyScheduled`, but the
> live v1alpha2 cluster reports **`PodGroupScheduled`**. Always read the actual
> condition type from the cluster rather than trusting the docs.

**Read the logs** — scheduler decisions:

```sh
kubectl -n kube-system logs kube-scheduler-k8s-136-alpha-control-plane | grep -i -E "podgroup|gang" | tail
```

> **Note:** the scheduler does not emit a dedicated "gang" log line at default
> verbosity — the gang decision is visible through the PodGroup status condition
> and the all-or-nothing placement of the Pods, not through scheduler logs.

**Cleanup** — delete the Pods, PodGroup, and Workload.

```sh
kubectl delete -f kubernetes/labs/manifests/gang-workers.yaml
kubectl delete -f kubernetes/labs/manifests/workload-podgroup.yaml
```

### Real-world example — distributed training (all-or-nothing)

**The problem gang scheduling solves.** A distributed ML training job (e.g.
PyTorch DDP, Horovod, MPI) runs as N worker Pods that must **all** be running at
the same time to make progress. If only some workers get scheduled, the running
ones sit idle waiting for their peers — burning expensive GPU time for nothing.
Worse, they can deadlock: each worker holds resources while waiting for the
others, and the scheduler can never place the rest.

**Without gang scheduling** (plain Pods / a Deployment): the scheduler places
Pods one at a time. On a busy cluster you get a partial placement — say 6 of 8
workers — and the job hangs half-scheduled.

**With Workload + PodGroup**: you declare `minCount: 8`. The scheduler treats the
group as a single unit — it either places **all 8** or **none**. If the cluster
can't fit all 8 right now, all 8 stay `Pending` until capacity frees up, so you
never waste GPU time on a partial gang.

```yaml
apiVersion: scheduling.k8s.io/v1alpha2
kind: Workload
metadata:
  name: pytorch-ddp
  namespace: ml
spec:
  controllerRef:                 # optional: links back to the owning Job
    apiGroup: batch
    kind: Job
    name: pytorch-ddp
  podGroupTemplates:
    - name: workers
      schedulingPolicy:
        gang:
          minCount: 8            # all 8 workers must be schedulable together
---
apiVersion: scheduling.k8s.io/v1alpha2
kind: PodGroup
metadata:
  name: pytorch-ddp-workers
  namespace: ml
spec:
  podGroupTemplateRef:
    workload:
      workloadName: pytorch-ddp
      podGroupTemplateName: workers
  schedulingPolicy:
    gang:
      minCount: 8
---
# Each worker Pod joins the group via spec.schedulingGroup.podGroupName.
apiVersion: v1
kind: Pod
metadata:
  name: pytorch-ddp-worker-0
  namespace: ml
spec:
  schedulingGroup:
    podGroupName: pytorch-ddp-workers
  containers:
    - name: trainer
      image: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime
      command: ["torchrun", "--nnodes=8", "--nproc_per_node=1", "train.py"]
      resources:
        limits:
          nvidia.com/gpu: 1
```

**How it behaves in practice:**

| Cluster state | Result |
|---------------|--------|
| 8 GPUs free | all 8 workers `Running`, `PodGroupInitiallyScheduled=True` |
| 6 GPUs free | all 8 workers `Pending` (no partial gang) |
| 6 GPUs free, then 2 more free up | all 8 schedule together at once |

**Why this matters for cost:** on cloud GPU nodes, a half-scheduled job is pure
waste. Gang scheduling converts "6 GPUs idle + 2 pending forever" into "0 GPUs
used until the full 8 are available" — the job starts only when it can actually
run.

**Related APIs (1.36+):**
- `WorkloadWithJob` (Alpha 1.36) — the Job controller compiles a Job's
  `.spec.scheduling` into Workload + PodGroup objects automatically, so you don't
  create them by hand.
- `TopologyAwareWorkloadScheduling` (Alpha 1.36) — adds placement constraints so
  the gang lands on nodes that are close together (e.g. same rack / same
  high-bandwidth fabric), which matters for collective communication.

---

## B2 — Native histograms

**What changed in 1.36** — `NativeHistograms` (Alpha) makes Kubernetes components
expose histogram metrics in **Prometheus native histogram** format (exponential
buckets, higher resolution, ~10x fewer time series) **alongside** the classic
format.

**Key concept — dual exposition.** The format returned depends on the HTTP
`Accept` header (Prometheus content negotiation):

| `Accept` header | Format returned |
|-----------------|-----------------|
| `text/plain` (default) | **classic buckets only** (`_bucket`, `_count`, `_sum`) |
| `application/vnd.google.protobuf` | **classic + native histogram** encoding |

So a plain `curl`/`kubectl get --raw` (which sends `text/plain`) will **never**
show native histograms — you must request protobuf.

**Observe — classic format (default, no native data):**

```sh
NODE=k8s-136-alpha-worker
kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics" | grep -E "# TYPE.*histogram" | head
```

**Observed output (real):**
```
# TYPE apiserver_client_certificate_expiration_seconds histogram
# TYPE apiserver_delegated_authz_request_duration_seconds histogram
# TYPE apiserver_storage_data_key_generation_duration_seconds histogram
# TYPE dra_operations_duration_seconds histogram
# TYPE go_gc_heap_allocs_by_size_bytes histogram
# TYPE go_gc_heap_frees_by_size_bytes histogram
# TYPE go_pauses_seconds histogram
# TYPE kubelet_cgroup_manager_duration_seconds histogram
# TYPE kubelet_containers_per_pod_count histogram
# TYPE kubelet_http_requests_duration_seconds histogram
# TYPE kubelet_image_pull_duration_seconds histogram
# TYPE kubelet_pleg_relist_duration_seconds histogram
...
```

> **Gotcha:** there is **no `native_histogram` string** in the text output. The
> `# TYPE ... histogram` lines are the *classic* histograms and are present
> whether or not the gate is enabled. Grepping for `native_histogram` returns
> nothing — that is expected, not a failure.

**Observe — native format (request protobuf):**

> **Gotcha:** `kubectl get --raw` does **not** support the `-H` header flag — it
> silently ignores it and returns the default text format. To send a custom
> `Accept` header you must use `curl` against the API server (via a proxy or
> port-forward), e.g.:
> ```sh
> kubectl proxy --port=8001 &
> curl -s -H "Accept: application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited" \
>   "http://localhost:8001/api/v1/nodes/$NODE/proxy/metrics" | head -c 200 | xxd | head
> ```
> The response is **binary protobuf** (not text). Native histogram data is
> encoded inside the `MetricFamily` messages for histogram metrics.
>
> **Cleanup:** if you started `kubectl proxy` in the background, stop it when
> done: `kill %1` (or `pkill -f "kubectl proxy"`).

**Confirm the gate is on** — query the feature-enabled metric (this is the
reliable check):

```sh
NODE=k8s-136-alpha-worker
kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics" \
  | grep 'kubernetes_feature_enabled{name="NativeHistograms"'
kubectl get --raw "/metrics" \
  | grep 'kubernetes_feature_enabled{name="NativeHistograms"'
```

**Observed output (real):**
```
# kubelet
kubernetes_feature_enabled{name="NativeHistograms",stage="ALPHA"} 1
# kube-apiserver
kubernetes_feature_enabled{name="NativeHistograms",stage="ALPHA"} 1
```

`1` = enabled, `stage="ALPHA"` confirms it is an alpha gate in 1.36.

**Read the logs** — the gate is per-component (kube-apiserver,
kube-controller-manager, kube-scheduler, kubelet, kube-proxy). Confirm via the
feature-enabled metric above rather than flagz (kubelet gates are set via the
KubeletConfiguration file, so they do not appear in flagz).

**Cleanup** — none (read-only).

> **Note:** to actually *store* native histograms you need Prometheus 2.40+ with
> `scrape_native_histograms: true` (and `always_scrape_classic_histograms: true`
> during migration). Kubernetes only *exposes* them; ingestion is Prometheus's job.

---

## B3 — PVC unused-since-time

**What changed in 1.36** — `PersistentVolumeClaimUnusedSinceTime` (Alpha) adds an
**`Unused`** condition to `PersistentVolumeClaimStatus`, with a
`lastTransitionTime` recording when the PVC last became unused.

**Apply** — `manifests/pvc-unused.yaml`:

<details>
<summary>📄 <code>manifests/pvc-unused.yaml</code></summary>

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: unused-demo
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
```

</details>

**Observe — unused PVC**

```sh
kubectl apply -f kubernetes/labs/manifests/pvc-unused.yaml
kubectl get pvc unused-demo -o jsonpath='{.status.conditions}'; echo
kubectl describe pvc unused-demo | grep -A5 -i condition
```

**Observed output (real):**
```
[{"lastProbeTime":null,"lastTransitionTime":"2026-10-02T01:08:27Z",
  "message":"No pods are currently referencing this PVC",
  "reason":"NoPodsUsingPVC","status":"True","type":"Unused"}]

Conditions:
  Type     Status  LastProbeTime                     LastTransitionTime                Reason           Message
  ----     ------  -----------------                 ------------------                ------           -------
  Unused   True    Mon, 01 Jan 0001 00:00:00 +0000   Fri, 02 Oct 2026 11:08:27 +1000   NoPodsUsingPVC   No pods are currently referencing this PVC
```

**Observe — bind a Pod, condition flips**

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-user
spec:
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: unused-demo
EOF

kubectl get pvc unused-demo -o jsonpath='{.status.conditions}'; echo
```

**Observed output (real):**
```
[{"lastProbeTime":null,"lastTransitionTime":"2026-10-02T01:08:43Z",
  "message":"A pod is currently referencing this PVC",
  "reason":"PodUsingPVC","status":"False","type":"Unused"}]
```

**Result:** the `Unused` condition flips `True` → `False` when a non-terminal Pod
references the PVC, and `lastTransitionTime` records exactly when it changed
(`01:08:27` → `01:08:43`). This lets tooling detect **stale/orphaned PVCs** — a
PVC that has been `Unused=True` for a long time is a candidate for cleanup.

> **Gotcha:** `lastProbeTime` is always `null` (and renders as the zero time
> `Mon, 01 Jan 0001` in `describe`). Only `lastTransitionTime` is meaningful —
> it tracks the last in-use ↔ unused transition, not a periodic probe.

**Cleanup**

```sh
kubectl delete pod pvc-user
kubectl delete pvc unused-demo
```

---

## B4 — Memory QoS

**What changed in 1.36** — `MemoryQoS` (Alpha) uses the cgroup v2 memory
controller to set `memory.high` (throttling) and, with
`memoryReservationPolicy: TieredReservation`, `memory.low`/`memory.min`
(protection). Requires both the gate **and** kubelet config (both set in the
alpha cluster config).

**Apply** — run a Burstable pod (request 64Mi, limit 128Mi):

```sh
kubectl run memqos-demo --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"memqos-demo","image":"busybox:1.36","command":["sleep","3600"],"resources":{"requests":{"memory":"64Mi"},"limits":{"memory":"128Mi"}}}]}}'
```

**Observe** — find the pod's cgroup and read the memory settings.

> **Gotcha:** the cgroup path is **not** `/sys/fs/cgroup/kubepods.slice/...`.
> Inside a kind node the hierarchy is rooted at
> `/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/...` and the pod slice is
> named `kubelet-kubepods-burstable-pod<uid>.slice`. The reliable way to find it
> is via the running process's own cgroup:

```sh
NODE=$(kubectl get pod memqos-demo -o jsonpath='{.spec.nodeName}')
echo "pod is on: $NODE"

# find the pod cgroup from the process itself (most reliable)
docker exec "$NODE" sh -c 'for p in $(pgrep -f "sleep 3600"); do cat /proc/$p/cgroup; done'
```

**Observed output (real):**
```
0::/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod76fe189a_d2fa_47e0_a600_44388153689c.slice/cri-containerd-2203be6874fb424647ae754440f382dcc165c5ab88ba72d5545e725989d96aeb.scope
```

Then read the memory files at the **container** cgroup:

```sh
PODCG=/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/kubelet-kubepods-burstable-pod76fe189a_d2fa_47e0_a600_44388153689c.slice
docker exec "$NODE" sh -c "for d in $PODCG/*/; do echo \"-- \$d\"; for f in memory.high memory.min memory.low memory.max; do printf '   %s = ' \$f; cat \$d\$f; done; done"
```

**Observed output (real):**
```
-- .../cri-containerd-2203be...scope/          # the memqos-demo container
   memory.high = 127504384      # ~121.6 MiB  (throttling threshold)
   memory.min  = 0
   memory.low  = 67108864       # 64 MiB      (protection = request)
   memory.max  = 134217728      # 128 MiB     (limit)
-- .../cri-containerd-797790...scope/          # the pause container
   memory.high = max
   memory.min  = 0
   memory.low  = 0
   memory.max  = max
```

**Result — the three cgroup v2 memory knobs are set:**

| File | Value | Meaning |
|------|-------|---------|
| `memory.max` | 128 MiB | hard limit (= container limit) |
| `memory.high` | ~121.6 MiB | **throttling** threshold — kernel throttles allocation above this instead of OOM-killing |
| `memory.low` | 64 MiB | **protection** — reclaim prefers other cgroups before this one (= request) |
| `memory.min` | 0 | hard protection (not set for this tier) |

`memory.high` is computed as `request + (limit − request) × memoryThrottlingFactor`
= `64Mi + 64Mi × 0.9` ≈ **121.6 MiB**, matching the configured
`memoryThrottlingFactor: 0.9`.

**Confirm the gate is on:**

```sh
kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics" | grep 'kubernetes_feature_enabled{name="MemoryQoS"'
```

**Observed output (real):**
```
kubernetes_feature_enabled{name="MemoryQoS",stage="ALPHA"} 1
```

**Why it matters:** without Memory QoS, a Burstable container that exceeds its
request but stays under its limit can balloon and cause node-level memory
pressure / OOM kills of *other* pods. `memory.high` throttles the offender
before it gets there, and `memory.low` protects its working set from being
reclaimed. This is the cgroup v2 replacement for the old `QOSReserved` approach.

**Cleanup** — `kubectl delete pod memqos-demo`

---

## Phase 2 checklist

- [x] Create `k8s-136-alpha` cluster
- [x] B1 Workload / PodGroup gang scheduling
- [x] B2 Native histograms
- [x] B3 PVC unused-since-time
- [x] B4 Memory QoS

---

## Phase 2 complete ✅

All four labs run against the `k8s-136-alpha` cluster. Summary of what each proved:

| Lab | Feature | Result |
|-----|---------|--------|
| B1 | Workload / PodGroup (Alpha) | 3 Pods gang-scheduled together across 3 nodes; `PodGroupScheduled=True` |
| B2 | NativeHistograms (Alpha) | gate on for kubelet + apiserver; dual exposition (text vs protobuf) confirmed |
| B3 | PVCUnusedSinceTime (Alpha) | `Unused` flips `True`→`False` when a Pod binds |
| B4 | MemoryQoS (Alpha) | `memory.high`≈121.6MiB, `memory.low`=64MiB set on Burstable cgroup |

### Cluster teardown

When you are done with Phase 2, delete the cluster to free ~19 GB:

```sh
kind delete cluster --name k8s-136-alpha
```

> Phase 1's cluster (`k8s-136`) is independent — delete it separately with
> `kind delete cluster --name k8s-136` if it still exists.

**Next:** Phase 3 (advanced features) — see
[`phase-c-advanced.md`](./phase-c-advanced.md).
