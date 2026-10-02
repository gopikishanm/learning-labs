# Kubernetes 1.36 Feature Labs

Hands-on labs to explore the improvements shipped in **Kubernetes v1.36**, run
against the kind cluster created in [`kind-v1.36-setup.md`](../kind-v1.36-setup.md).

Each phase has its **own document** so it can be resumed independently:

| Phase | Requires | Cluster | Doc | Status |
|-------|----------|---------|-----|--------|
| **1 (A)** | Nothing extra — features are GA or beta-on-by-default | `k8s-136` (existing) | [phase-a-ga-beta.md](./phase-a-ga-beta.md) | ✅ **Complete** |
| **2 (B)** | Feature gates set at cluster creation | `k8s-136-alpha` (new) | [phase-b-alpha-feature-gates.md](./phase-b-alpha-feature-gates.md) | ✅ Complete |
| **3 (C)** | Extra components / advanced setup | `k8s-136` or alpha | [phase-c-advanced.md](./phase-c-advanced.md) | ⏳ Not started |

> **Why separate phases?** Feature gates are immutable after cluster creation.
> Phase 1 runs on the cluster you already have; Phase 2 needs a second cluster
> created with `featureGates` in the kind config. Keeping them separate means
> `k8s-136` stays clean and reproducible.

---

## Prerequisites

- The `k8s-136` cluster from `kind-v1.36-setup.md` is running (`kubectl get nodes` → 4 Ready)
- `kubectl` v1.36.x
- For Phase 2: enough Docker memory to run a second 4-node cluster, **or** delete
  `k8s-136` first (see Phase 2 doc)

---

## Phase 1 — GA & beta-on-by-default features

Runs on the existing cluster. No recreate needed.

| # | Lab | Feature | Kind |
|---|-----|---------|------|
| A1 | CLI tour | Architecture in `KERNEL-VERSION`, `explain -r`, `wait` multi-condition, ResourceSlices in `describe node` | GA |
| A2 | MutatingAdmissionPolicy | CEL-based mutation without a webhook | GA v1 |
| A3 | In-place pod resize | Container + pod-level resource resize | GA / Beta |
| A4 | RestartAllContainers | `restartPolicyRules` restart-all action | Beta |
| A5 | NodeLogQuery | Query kubelet logs via the API | GA |
| A6 | KubeletPSI | Pressure Stall Information metrics | GA |
| A7 | flagz / statusz | Component introspection endpoints | Beta |
| A8 | ImageVolume | Mount an OCI image as a volume | GA |
| A9 | UserNamespaces / ProcMountType | Pod security features | GA |
| A10 | Validation changes | Relaxed service names, strict IP/CIDR | Beta |

## Phase 2 — Alpha features behind feature gates

Requires a cluster created with the gates enabled.

| # | Lab | Feature gate |
|---|-----|--------------|
| B1 | Workload / PodGroup gang scheduling | `WorkloadAwarePreemption`, `TopologyAwareWorkloadScheduling` |
| B2 | Native histograms | `NativeHistograms` (Prometheus) |
| B3 | PVC unused-since-time | `PersistentVolumeClaimUnusedSinceTime` |
| B4 | Memory QoS | `MemoryQoS` / `MemoryReservationPolicy` |

## Phase 3 — Advanced / optional

| # | Lab | Notes |
|---|-----|-------|
| C1 | Dynamic Resource Allocation (DRA) | Needs an example DRA driver |
| C2 | ConstrainedImpersonation | Beta; RBAC-scoped impersonation |
| C3 | ManifestBasedAdmissionControlConfig | Alpha; CEL policy from static manifest |

---

## Conventions used in the lab docs

Each lab follows the same shape:

1. **What changed in 1.36** — the feature and its graduation status
2. **Apply** — the manifest / command
3. **Observe** — expected output (filled with real output as labs are run)
4. **Read the logs** — where to look and what to look for
5. **Cleanup**

Manifests live in [`manifests/`](./manifests/).

### Manifest error documentation convention

When a manifest fails validation and is fixed, the **manifest itself** carries a
header comment block documenting the error and the fix, in this format:

```yaml
# <file>.yaml — Lab <X> (<feature>, <status> in 1.36)
#
# ============================================================================
# ERRORS ENCOUNTERED AND FIXES
# ============================================================================
#
# ERROR N:
#   <exact error message from kubectl>
#
#   CAUSE: <why it happened>
#
#   FIX:   <what change resolves it>
#
#   BEFORE:
#     <the broken snippet>
#
#   AFTER:
#     <the corrected snippet>
#
# ============================================================================
```

This keeps the "what went wrong / why / how it was fixed" next to the code, so
the lab is reproducible and the failure mode is a teaching point.

