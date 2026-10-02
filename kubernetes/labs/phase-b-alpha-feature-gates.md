# Phase 2 — Kubernetes 1.36 Alpha Features (Feature Gates)

> **Status: NOT STARTED.** Resume here after Phase 1.

These features are **Alpha** and must be enabled with `featureGates` at cluster
creation. Feature gates are immutable, so this phase needs a **second cluster**.

## Cluster

Create `k8s-136-alpha` from `../kind-v1.36-alpha-cluster.yaml` (to be written),
which adds:

```yaml
featureGates:
  WorkloadAwarePreemption: true
  TopologyAwareWorkloadScheduling: true
  PersistentVolumeClaimUnusedSinceTime: true
  MemoryQoS: true
  NativeHistograms: true
```

> **Memory note:** a second 4-node cluster needs ~19 GB. Either delete `k8s-136`
> first (`kind delete cluster --name k8s-136`) or reduce the alpha cluster to
> 1 CP + 1 worker.

## Labs (to be detailed)

- **B1 Workload / PodGroup gang scheduling** — `scheduling.k8s.io/v1alpha2`
  `Workload` + `PodGroup`; observe all-or-nothing scheduling.
- **B2 Native histograms** — scrape `/metrics` and show native histogram format.
- **B3 PVC unused-since-time** — `Unused` condition on PVC.
- **B4 Memory QoS** — `MemoryReservationPolicy`; inspect cgroup `memory.min`.

## TODO when resuming
- [ ] Write `kind-v1.36-alpha-cluster.yaml`
- [ ] Verify gate names against `kubectl get --raw .../flagz`
- [ ] Detail each lab (apply / observe / logs / cleanup)
