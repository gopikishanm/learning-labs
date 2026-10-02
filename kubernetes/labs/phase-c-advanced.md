# Phase 3 — Advanced / Optional Labs

> **Status:** ⏳ Not started. Cluster decision made; labs to be run.

Phase 3 covers three advanced features. Unlike Phases 1–2, **not all of them need
a new cluster** — two run on the existing `k8s-136-alpha` cluster, one needs a
fresh cluster because its gate is disabled.

---

## Cluster decision

Gate status on the existing `k8s-136-alpha` cluster (verified via
`kubernetes_feature_enabled`):

| Lab | Gate | Stage | On? | Cluster |
|-----|------|-------|-----|---------|
| C1 DRA | `DynamicResourceAllocation` | Stable | ✅ | **existing** |
| C1 DRA | `DRAConsumableCapacity` | Beta | ✅ | **existing** |
| C2 ConstrainedImpersonation | `ConstrainedImpersonation` | Beta | ✅ | **existing** |
| C3 ManifestBasedAdmissionControlConfig | `ManifestBasedAdmissionControlConfig` | Alpha | ❌ | **new cluster** |

**Plan:**
1. Run **C1 + C2** on `k8s-136-alpha` (no new cluster).
2. Create a **new cluster** `k8s-136-mac` for **C3** (gate is immutable + off).

> **Memory note:** only one 4-node cluster (~19 GB) fits at a time. Delete
> `k8s-136-alpha` before creating the C3 cluster:
> ```sh
> kind delete cluster --name k8s-136-alpha
> ```

---

## C1 — Dynamic Resource Allocation (DRA)

**What changed in 1.36** — DRA is **Stable** (`resource.k8s.io/v1`). It lets Pods
request *structured* resources (GPUs, FPGAs, NICs) via `ResourceClaim` /
`ResourceClaimTemplate` objects, and the scheduler allocates them. In 1.36,
`DRAConsumableCapacity` (device sharing) is **Beta** and on by default.

**Why it matters** — the old device-plugin model exposed devices as opaque
extended resources (`nvidia.com/gpu: 1`) with no way to express *which* device or
*how* to configure it. DRA makes devices first-class: drivers publish
`ResourceSlice`s describing device attributes/capacity, and claims select devices
with CEL expressions.

**Prerequisite — a DRA driver.** DRA needs a driver to publish devices. We use the
upstream [`dra-example-driver`](https://github.com/kubernetes-sigs/dra-example-driver)
(mock GPUs, no real hardware needed).

> **Build requirement:** the example driver is built from source and needs
> **Go 1.26+**, **GNU Make**, and **Docker buildx**. On Apple Silicon the
> `linux/arm64` build runs natively.

**Install the driver:**

```sh
git clone https://github.com/kubernetes-sigs/dra-example-driver.git
cd dra-example-driver

# build the driver image (arm64 native on Apple Silicon)
./demo/build-driver.sh
# -> Driver build complete: registry.k8s.io/dra-example-driver/dra-example-driver:v0.5.0

# load the image into the kind nodes (use the EXACT tag the build printed)
kind load docker-image registry.k8s.io/dra-example-driver/dra-example-driver:v0.5.0 \
  --name k8s-136-alpha

# install via Helm
helm upgrade -i --create-namespace \
  --namespace dra-example-driver \
  dra-example-driver \
  deployments/helm/dra-example-driver
```

> **Gotcha:** the built image name/tag is **not** `registry.example.com/...:latest`.
> `build-driver.sh` prints the real reference (here
> `registry.k8s.io/dra-example-driver/dra-example-driver:v0.5.0`). Use that exact
> string for `kind load docker-image`, or the nodes won't have the image and the
> driver pods will `ImagePullBackOff`.

**Observe — the driver publishes devices:**

```sh
kubectl get pods -n dra-example-driver
kubectl get resourceslices
kubectl get deviceclasses
```

**Observed output (real):**
```
$ kubectl get pods -n dra-example-driver
NAME                                     READY   STATUS    RESTARTS   AGE
 dra-example-driver-kubeletplugin-58lv4   1/1     Running   0          17s
dra-example-driver-kubeletplugin-k7c2j   1/1     Running   0          17s
dra-example-driver-kubeletplugin-tdft9   1/1     Running   0          17s

$ kubectl get resourceslices
NAME                                                NODE                    DRIVER            POOL
00000-gpu.example.com-k8s-136-alpha-worker-q75wb    k8s-136-alpha-worker    gpu.example.com   k8s-136-alpha-worker
00000-gpu.example.com-k8s-136-alpha-worker2-wbbb8   k8s-136-alpha-worker2   gpu.example.com   k8s-136-alpha-worker2
00000-gpu.example.com-k8s-136-alpha-worker3-fzlh4   k8s-136-alpha-worker3   gpu.example.com   k8s-136-alpha-worker3

$ kubectl get deviceclasses
NAME              AGE
gpu.example.com   17s
```

One `kubeletplugin` pod per worker, one `ResourceSlice` per node, and a
`gpu.example.com` `DeviceClass` — the driver is publishing mock GPU devices.

**Apply — a ResourceClaimTemplate + Pod:**

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-claim
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: gpu.example.com
            count: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: dra-demo
spec:
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: gpu-claim
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh", "-c", "env | grep GPU_DEVICE; sleep 3600"]
      resources:
        claims:
          - name: gpu
```

**Observe — allocation:**

```sh
kubectl apply -f kubernetes/labs/manifests/dra-claim.yaml
kubectl get resourceclaims
kubectl get pod dra-demo -o wide
kubectl logs dra-demo | grep GPU_DEVICE
```

**Observed output (real):**
```
$ kubectl get pods dra-demo -o wide
NAME       READY   STATUS    RESTARTS   AGE   IP           NODE
dra-demo   1/1     Running   0          6s    10.244.3.5   k8s-136-alpha-worker2

$ kubectl get resourceclaims
NAME                 STATE                AGE
dra-demo-gpu-p8l6t   allocated,reserved   6s

$ kubectl logs dra-demo | grep GPU_DEVICE
GPU_DEVICE_0_TIMESLICE_INTERVAL=Default
GPU_DEVICE_0=gpu-0
GPU_DEVICE_GPU_0_RESOURCE_CLAIM=26a3f8db-735d-439a-a136-b1303caf7098
GPU_DEVICE_0_SHARING_STRATEGY=TimeSlicing
```

**Result:** the claim is `allocated,reserved`, the Pod is `Running`, and the
container received `GPU_DEVICE_0=gpu-0` — the driver injected the mock GPU and
its sharing config (`TimeSlicing`) as env vars.

> **Gotcha:** the claim name is auto-generated (`dra-demo-gpu-<suffix>`) because
> it came from a `ResourceClaimTemplate`. The `GPU_DEVICE_*_RESOURCE_CLAIM` env
> var carries the claim UID, linking the container back to its allocation.

**Read the logs** — scheduler allocation:

```sh
kubectl -n kube-system logs kube-scheduler-k8s-136-alpha-control-plane --since=2m | grep -i -E "resourceclaim|dynamicresources" | tail
```

**Cleanup**

```sh
# 1. remove the lab workload
kubectl delete pod dra-demo
kubectl delete resourceclaimtemplate gpu-claim

# 2. uninstall the driver from the cluster
helm uninstall -n dra-example-driver dra-example-driver
kubectl delete namespace dra-example-driver

# 3. remove the built image from the kind nodes
docker rmi registry.k8s.io/dra-example-driver/dra-example-driver:v0.5.0

# 4. remove the cloned repo (and its build artifacts)
cd ..
rm -rf dra-example-driver
```

> **Note:** step 4 deletes the entire cloned `dra-example-driver` directory,
> including the built image context and any local changes. If you want to keep it
> for a later re-run, skip step 4 — the driver can be reinstalled with
> `helm upgrade -i` without rebuilding.

---

## C2 — ConstrainedImpersonation

**What changed in 1.36** — `ConstrainedImpersonation` (Beta, on by default)
enables impersonation that is **constrained to specific requests** instead of
being all-or-nothing. Historically, if you could impersonate a user you could do
*everything* as that user; constrained impersonation lets an admin grant
impersonation that is limited in scope.

**Why it matters** — it lets you build safer "act-as" workflows (support
tooling, debugging, multi-tenant controllers) without handing over the full
identity.

**Observe — baseline impersonation works:**

```sh
# who am I normally?
kubectl auth whoami

# impersonate a user and a group
kubectl auth whoami --as=alice --as-group=developers
```

**Observed output (real):**
```
$ kubectl auth whoami
ATTRIBUTE                                           VALUE
Username                                            kubernetes-admin
Groups                                              [kubeadm:cluster-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=978f6d5d...]

$ kubectl auth whoami --as=alice --as-group=developers
ATTRIBUTE   VALUE
Username    alice
Groups      [developers system:authenticated]
```

**Observe — impersonation is RBAC-gated:**

```sh
# create a ServiceAccount that may NOT impersonate
kubectl create serviceaccount impersonator

# try to impersonate as that SA (should be Forbidden)
kubectl auth can-i impersonate users --as=system:serviceaccount:default:impersonator
```

**Observed output (real):**
```
serviceaccount/impersonator created
no
```

**Grant constrained impersonation** — a ClusterRole scoped to a **specific
resourceName** (`alice`), not all users:

```sh
kubectl create clusterrole impersonate-alice \
  --verb=impersonate --resource=users --resource-name=alice
kubectl create clusterrolebinding impersonate-alice \
  --clusterrole=impersonate-alice \
  --user=system:serviceaccount:default:impersonator
```

**Observe — the constraint.** Build a **token-only kubeconfig** so the request is
actually made *as the ServiceAccount* (a client cert would otherwise win and the
request would run as `kubernetes-admin`, which can impersonate anyone):

```sh
CTX=kind-k8s-136-alpha
SERVER=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$CTX')].cluster.server}")
CA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$CTX')].cluster.certificate-authority-data}")
TOKEN=$(kubectl create token impersonator --duration=1h)
cat > /tmp/sa.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- name: c
  cluster:
    server: $SERVER
    certificate-authority-data: $CA
users:
- name: sa
  user:
    token: $TOKEN
contexts:
- name: sa
  context:
    cluster: c
    user: sa
current-context: sa
EOF

# baseline: who is the SA?
kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami
# allowed: impersonate alice (in the role's resourceName)
kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami --as=alice
# denied: impersonate bob (NOT in the role)
kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami --as=bob
```

**Observed output (real):**
```
$ kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami
Username    system:serviceaccount:default:impersonator
UID         5e2ba99d-adca-4a44-90bc-2fe4a2b8e8dd
Groups      [system:serviceaccounts system:serviceaccounts:default system:authenticated]

$ kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami --as=alice
Username    alice
Groups      [system:authenticated]

$ kubectl --kubeconfig=/tmp/sa.kubeconfig auth whoami --as=bob
error: the selfsubjectreviews API is not enabled in the cluster or you do not have permission to call it
```

**Result:** the ServiceAccount can impersonate **alice** (allowed by the
resourceName-scoped role) but **not bob** — the impersonation is *constrained* to
the specific user named in the RBAC rule. This is the core of
`ConstrainedImpersonation`: instead of all-or-nothing `impersonate users`, you
grant `impersonate users/alice`.

> **Gotcha 1:** `kubectl auth can-i impersonate users --subresource=alice` is
> **not** the right test — `--subresource` is for API subresources, not
> resourceNames, and returns `no` even when the grant exists. Test by actually
> impersonating.
>
> **Gotcha 2:** `kubectl auth whoami --token=...` does **not** override a client
> cert in the kubeconfig — the cert wins and the request runs as
> `kubernetes-admin`. You must use a **token-only kubeconfig** to act as the SA.
>
> **Gotcha 3:** the denial surfaces as
> `the selfsubjectreviews API is not enabled ... or you do not have permission`
> — a slightly misleading message; the real cause is that the SA lacks
> `impersonate users/bob`.

**Read the metrics** — impersonation activity:

```sh
kubectl get --raw "/metrics" | grep -i impersonation | head
```

**Observed output (real):**
```
# HELP apiserver_impersonation_attempts_duration_seconds [ALPHA] Latency of impersonation attempts in seconds split by mode and decision.
# TYPE apiserver_impersonation_attempts_duration_seconds histogram
apiserver_impersonation_attempts_duration_seconds_bucket{decision="allowed",mode="serviceaccount",le="0.001"} 9
apiserver_impersonation_attempts_duration_seconds_bucket{decision="allowed",mode="serviceaccount",le="0.002"} 9
...
```

The metric is split by `decision` (`allowed`/`denied`) and `mode`
(`serviceaccount`/`user`), so you can alert on denied impersonation attempts.

**Cleanup**

```sh
kubectl delete clusterrolebinding impersonate-alice
kubectl delete clusterrole impersonate-alice
kubectl delete serviceaccount impersonator
rm -f /tmp/sa.kubeconfig
```

---

## C3 — ManifestBasedAdmissionControlConfig

**What changed in 1.36** — `ManifestBasedAdmissionControlConfig` (Alpha,
KEP-5793) lets the API server load admission webhooks and CEL-based admission
policies from **static manifest files on disk** via the `staticManifestsDir`
field in `AdmissionConfiguration`. These policies are active **from API server
startup**, survive etcd unavailability, and can protect API-based admission
resources from modification.

**Why it matters** — normal admission policies live in etcd, so a compromised or
misconfigured cluster could delete them. Manifest-based policies are loaded from
disk before the API is serving, giving a bootstrap/break-glass layer that cannot
be removed via the API.

**This needs a new cluster** — the gate is Alpha and disabled, and feature gates
are immutable.

**How it works (the mechanism):**

1. Enable the `ManifestBasedAdmissionControlConfig` gate on the **kube-apiserver**
   (it is apiserver-only — do NOT set it cluster-wide).
2. Pass an `AdmissionConfiguration` file to the apiserver via
   `--admission-control-config-file`. It names a `staticManifestsDir` per plugin.
3. Put the policy manifests in that directory. The apiserver loads them at
   startup and **fails to start** if any are invalid.

**Key rules for manifest files:**
- Object names **must** end with `.static.k8s.io` (e.g. `deny-privileged.static.k8s.io`).
- `spec.paramKind` / `spec.paramRef` are **not allowed** (no API references).
- A binding's `policyName` must reference a policy in the **same** manifest set.
- Only `admissionregistration.k8s.io/v1` is supported.

**Files created for this lab:**
- `manifests/static-admission/admission-configuration.yaml` — the `AdmissionConfiguration`
- `manifests/static-admission/policies/deny-privileged.yaml` — a static CEL policy
  that denies privileged containers outside `kube-system`

**Create the C3 cluster** (delete the alpha cluster first to free memory):

```sh
kind delete cluster --name k8s-136-alpha
kind create cluster --name k8s-136-mac --config kubernetes/kind-v1.36-mac-cluster.yaml
kubectl config use-context kind-k8s-136-mac
kubectl get nodes
```

The cluster config:
- enables `ManifestBasedAdmissionControlConfig=true` on the apiserver,
- sets `--admission-control-config-file=/etc/kubernetes/admission/admission-configuration.yaml`,
- mounts the repo's `manifests/static-admission/` dir into the node at
  `/etc/kubernetes/admission/` (read-only),
- adds an apiserver `extraVolumes` entry so the admission dir is mounted into the
  **static pod** (see ERROR 1 below).

### ERROR 1: apiserver fails to start — admission config not found

**SYMPTOM**
```
ERROR: failed to create cluster: failed to init node with kubeadm: ...
error: error execution phase wait-control-plane: cannot obtain client without
bootstrap: could not bootstrap the admin user in file admin.conf: unable to
create ClusterRoleBinding: client rate limiter Wait returned an error: context
deadline exceeded
```
The apiserver static pod is written but never becomes healthy, so kubeadm times
out. The real cause is in the apiserver log:
```
E1002 ... run.go:72] "command failed" err="failed to apply admission: failed to
read plugin config: unable to read admission control configuration from
\"/etc/kubernetes/admission/admission-configuration.yaml\" [open
/etc/kubernetes/admission/admission-configuration.yaml: no such file or directory]"
```

**CAUSE** — kubeadm only mounts a **fixed set of host paths** into the
kube-apiserver static pod (`/etc/kubernetes/pki`, `/etc/ssl/certs`, etc.). The
`extraMounts` on the kind node put the files on the node, but they are **not**
visible inside the apiserver container. The `--admission-control-config-file`
path therefore does not exist and the apiserver exits.

**FIX** — add an `extraVolumes` entry to the apiserver's `ClusterConfiguration`
so kubeadm mounts the directory into the static pod.

**BEFORE:**
```yaml
        apiServer:
          extraArgs:
            - name: feature-gates
              value: "ManifestBasedAdmissionControlConfig=true"
            - name: admission-control-config-file
              value: "/etc/kubernetes/admission/admission-configuration.yaml"
```

**AFTER:**
```yaml
        apiServer:
          extraArgs:
            - name: feature-gates
              value: "ManifestBasedAdmissionControlConfig=true"
            - name: admission-control-config-file
              value: "/etc/kubernetes/admission/admission-configuration.yaml"
          extraVolumes:
            - name: admission-config
              hostPath: /etc/kubernetes/admission
              mountPath: /etc/kubernetes/admission
              readOnly: true
              pathType: DirectoryOrCreate
```

> **Tip:** any file the apiserver must read from disk needs an `extraVolumes`
> entry — the kind `extraMounts` alone is not enough.

**Observe — the gate is on:**

```sh
kubectl get --raw "/metrics" | grep 'kubernetes_feature_enabled{name="ManifestBasedAdmissionControlConfig"'
```

**Observed output (real):**
```
kubernetes_feature_enabled{name="ManifestBasedAdmissionControlConfig",stage="ALPHA"} 1
```

**Observe — the static policy is loaded (not visible via the API):**

```sh
# the policy is NOT an API object — it does not appear here:
kubectl get validatingadmissionpolicies
# but the reload controller reports it:
kubectl get --raw "/metrics" | grep apiserver_manifest_admission_config_controller_last_config_info
```

**Observed output (real):**
```
$ kubectl get validatingadmissionpolicies
No resources found

$ kubectl get --raw "/metrics" | grep apiserver_manifest_admission_config_controller_last_config_info
apiserver_manifest_admission_config_controller_last_config_info{apiserver_id_hash="sha256:f51bd8a8...",hash="sha256:95e35a4d...",plugin="ValidatingAdmissionPolicy"} 1
```
The policy exists **only on disk** — it is not an API object — yet the reload
controller confirms it is loaded (`plugin="ValidatingAdmissionPolicy"`, value `1`).

**Observe — the policy is enforced:**

```sh
# allowed: a normal pod
kubectl run ok --image=busybox:1.36 --restart=Never -- sleep 3600
# denied: a privileged pod (should be rejected by the static policy)
kubectl run bad --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"bad","image":"busybox:1.36","securityContext":{"privileged":true}}]}}'
```

**Observed output (real):**
```
$ kubectl run ok ...
pod/ok created

$ kubectl run bad ...
The pods "bad" is invalid: : ValidatingAdmissionPolicy
'example-deny-privileged.static.k8s.io' with binding
'example-deny-privileged-binding.static.k8s.io' denied request:
Privileged containers are not allowed
```

**Observe — the `.static.k8s.io` suffix is reserved:**

```sh
kubectl apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "my-policy.static.k8s.io"
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
EOF
```

**Observed output (real):**
```
The ValidatingAdmissionPolicy "my-policy.static.k8s.io" is invalid:
* metadata.name: Invalid value: "my-policy.static.k8s.io": names ending with
  ".static.k8s.io" are reserved for static manifest-based configurations and
  cannot be managed via the API
```

**Result:** the static policy is enforced from disk (privileged pods denied),
normal pods pass, and the `.static.k8s.io` suffix is reserved so the policy
cannot be shadowed or deleted via the API — exactly the self-protection property
that motivates manifest-based admission control.

**Read the logs** — apiserver loading the manifests:

```sh
kubectl -n kube-system logs kube-apiserver-k8s-136-mac-control-plane | grep -i -E "manifest|staticManifests|admission" | head
```

**Cleanup**

```sh
kubectl delete pod ok --ignore-not-found
kind delete cluster --name k8s-136-mac
```

---

## Phase 3 checklist

- [x] C1 DRA — install driver, allocate a mock GPU
- [x] C2 ConstrainedImpersonation — impersonate + RBAC gating
- [x] C3 ManifestBasedAdmissionControlConfig — new cluster + static policy

## TODO when resuming
- [x] Write `manifests/dra-claim.yaml`
- [x] Write `kind-v1.36-mac-cluster.yaml` (C3 cluster with the gate + staticManifestsDir)
- [x] Verify the exact ConstrainedImpersonation constraint mechanism against the cluster
- [x] Fill in real output for C3

---

## Phase 3 complete ✅

All three labs run. Summary of what each proved:

| Lab | Feature | Result |
|-----|---------|--------|
| C1 | DynamicResourceAllocation (Stable) | mock GPU allocated via ResourceClaimTemplate; `GPU_DEVICE_0=gpu-0` injected |
| C2 | ConstrainedImpersonation (Beta) | SA can impersonate `alice` but not `bob` (resourceName-scoped RBAC) |
| C3 | ManifestBasedAdmissionControlConfig (Alpha) | static CEL policy loaded from disk; privileged pod denied; `.static.k8s.io` reserved |

### Cluster teardown

```sh
kind delete cluster --name k8s-136-mac
```

> The DRA driver image and cloned repo can also be removed (see C1 cleanup).

---

## All phases complete 🎉

| Phase | Cluster | Labs | Doc |
|-------|---------|------|-----|
| 1 | `k8s-136` | A1–A10 (GA/Beta) | [phase-a-ga-beta.md](./phase-a-ga-beta.md) |
| 2 | `k8s-136-alpha` | B1–B4 (Alpha gates) | [phase-b-alpha-feature-gates.md](./phase-b-alpha-feature-gates.md) |
| 3 | `k8s-136-alpha` + `k8s-136-mac` | C1–C3 (advanced) | this file |
