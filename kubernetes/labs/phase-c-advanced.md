# Phase 3 — Advanced / Optional Labs

> **Status: NOT STARTED.** Resume after Phase 2.

- **C1 Dynamic Resource Allocation (DRA)** — install an example DRA driver
  (e.g. `dra-example-driver`), create `ResourceClaim`/`ResourceClaimTemplate`,
  consume in a pod. 1.36: DRA extended resources Beta, `DRAConsumableCapacity`
  on by default, `DRAListTypeAttributes`/`DRANodeAllocatableResources` Alpha.
- **C2 ConstrainedImpersonation** (Beta) — impersonate with RBAC-scoped
  permissions; inspect `apiserver_impersonation_*` metrics.
- **C3 ManifestBasedAdmissionControlConfig** (Alpha, KEP-5793) — load a CEL
  admission policy from a static manifest on disk.

## TODO when resuming
- [ ] Pick DRA driver + version compatible with 1.36
- [ ] Detail each lab (apply / observe / logs / cleanup)
