# Phase 1 — Kubernetes 1.36 GA & Beta-on-by-default Features

Runs on the existing **`k8s-136`** cluster (v1.36.4). No recreate required.

```sh
kubectl config use-context kind-k8s-136
kubectl get nodes
```

> **Status:** ✅ **Phase 1 complete** — all ten labs (A1–A10) run and documented
> with real output.

---

## A1 — CLI tour

**What changed in 1.36**
- `kubectl get node -o wide` now appends the **architecture** to the
  `KERNEL-VERSION` column (e.g. `6.12.76-linuxkit (arm64)`).
- `kubectl explain -R` is shorthand for `--recursive` (**capital `R`** — the
  changelog wrote `-r`, but the actual flag is `-R`).
- `kubectl wait` supports **multiple conditions**.
- `kubectl describe node` lists aggregated **ResourceSlices** (DRA).
- `kubectl exec`/`logs` list valid container names when you typo one.

**Apply / Observe**

```sh
kubectl get nodes -o wide
```

```text
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION             CONTAINER-RUNTIME
k8s-136-control-plane   Ready    control-plane   10m   v1.36.4   172.18.0.3    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker          Ready    <none>          10m   v1.36.4   172.18.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker2         Ready    <none>          10m   v1.36.4   172.18.0.4    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
k8s-136-worker3         Ready    <none>          10m   v1.36.4   172.18.0.5    <none>        Debian GNU/Linux 13 (trixie)   6.12.76-linuxkit (arm64)   containerd://2.3.4
```

> **Note:** the architecture appears inside `KERNEL-VERSION` as `(arm64)`, not as
> a separate `ARCH` column. This matches the 1.36 changelog wording: *"Add
> architecture to the kernel version column in `kubectl get node -o wide`."*

```sh
# recursive explain shorthand (capital -R)
kubectl explain pod.spec.containers -R | head -40
```

```text
KIND:       Pod
VERSION:    v1

FIELD: containers <[]Container>


DESCRIPTION:
    List of containers belonging to the pod. Containers cannot currently be
    added or removed. There must be at least one container in a Pod. Cannot be
    updated.
    A single application container that you want to run within a pod.

FIELDS:
  args	<[]string>
  command	<[]string>
  env	<[]EnvVar>
    name	<string> -required-
    value	<string>
    valueFrom	<EnvVarSource>
      configMapKeyRef	<ConfigMapKeySelector>
        key	<string> -required-
        name	<string>
        optional	<boolean>
      fieldRef	<ObjectFieldSelector>
        apiVersion	<string>
        fieldPath	<string> -required-
      fileKeyRef	<FileKeySelector>
        key	<string> -required-
        optional	<boolean>
        path	<string> -required-
        volumeName	<string> -required-
      resourceFieldRef	<ResourceFieldSelector>
        containerName	<string>
        divisor	<Quantity>
        resource	<string> -required-
      secretKeyRef	<SecretKeySelector>
        key	<string> -required-
        name	<string>
        optional	<boolean>
  envFrom	<[]EnvFromSource>
```

> **Gotcha:** `kubectl explain -r` fails with `unknown shorthand flag: 'r' in -r`.
> The correct shorthand is **`-R`** (capital). Confirmed against client
> `v1.36.1`:
>
> ```text
> -R, --recursive=false:
> ```

```sh
# create a target workload for the next two commands
kubectl create deployment nginx --image=nginx

# multiple conditions (1.36: --for can be repeated)
kubectl wait --for=condition=Ready --for=jsonpath='{.status.phase}'=Running pod -l app=nginx --timeout=60s

# typo a container name -> kubectl suggests valid ones
kubectl logs deploy/nginx -c ngnix
```

```text
deployment.apps/nginx created
pod/nginx-7f8fbb96d-9hz6s condition met
pod/nginx-7f8fbb96d-9hz6s condition met
error: container ngnix is not valid for pod nginx-7f8fbb96d-9hz6s out of: nginx
```

**Observe** — `kubectl wait` accepts **two** `--for` flags and prints
`condition met` **once per condition** (two lines). The typo command errors but
*lists the valid container names* (`out of: nginx`), a 1.36 UX improvement.

> **Gotcha:** running `kubectl wait ... -l app=nginx` before the deployment exists
> fails with `error: no matching resources found`. Create the deployment first.

**Cleanup**

```sh
kubectl delete deployment nginx
```

```text
deployment.apps "nginx" deleted from default namespace
```

---

## A2 — MutatingAdmissionPolicy (GA v1)

**What changed in 1.36** — `MutatingAdmissionPolicy` graduated to **GA (`v1`)** and
is enabled by default. It mutates objects using **CEL** — no webhook, no TLS, no
extra deployment.

**Apply** — `manifests/mutating-admission-policy.yaml`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata:
  name: add-lab-label
spec:
  failurePolicy: Fail
  reinvocationPolicy: Never
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: |
          Object{
            metadata: Object.metadata{
              labels: {"mutated-by": "k8s-1.36-lab"}
            }
          }
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata:
  name: add-lab-label-binding
spec:
  policyName: add-lab-label
  matchResources: {}
```

> **Gotcha (two errors hit while building this lab):**
>
> 1. **CEL is not imperative.** `Object.metadata.labels["x"] = "y"` fails to
>    compile — CEL has no assignment operator. Use an **object-construction**
>    expression instead:
>    ```text
>    ERROR: <input>:1:38: Syntax error: token recognition error at: '= '
>    ```
> 2. **`spec.reinvocationPolicy` is required** in `v1`:
>    ```text
>    * spec.reinvocationPolicy: Required value
>    ```
>    Set it to `Never` (or `IfNeeded`).
>
> Also note the binding is created **before** the policy is validated, so a failed
> apply can leave an orphan binding — re-apply after fixing the policy.

```sh
kubectl apply -f kubernetes/labs/manifests/mutating-admission-policy.yaml
kubectl run map-test --image=nginx
kubectl get pod map-test -o jsonpath='{.metadata.labels}'; echo
```

```text
mutatingadmissionpolicy.admissionregistration.k8s.io/add-lab-label created
mutatingadmissionpolicybinding.admissionregistration.k8s.io/add-lab-label-binding unchanged
pod/map-test created
{"mutated-by":"k8s-1.36-lab","run":"map-test"}
```

**Observe** — the pod carries `mutated-by=k8s-1.36-lab` even though you never set
it. The mutation was applied by the API server via CEL — **no webhook**.

**Read the logs** — the mutation is applied by the API server, so check the
apiserver logs:

```sh
kubectl -n kube-system logs kube-apiserver-k8s-136-control-plane | grep -i mutatingadmissionpolicy | tail
```

```text
I1001 23:49:38.448625       1 plugins.go:157] Loaded 15 mutating admission controller(s) successfully in the following order: NamespaceLifecycle,LimitRanger,ServiceAccount,NodeRestriction,TaintNodesByCondition,Priority,DefaultTolerationSeconds,DefaultStorageClass,StorageObjectInUseProtection,PodGroupProtection,RuntimeClass,DefaultIngressClass,PodTopologyLabels,MutatingAdmissionPolicy,MutatingAdmissionWebhook.
```

> **Reading the log:** `MutatingAdmissionPolicy` appears in the admission
> controller chain **before** `MutatingAdmissionWebhook` — confirming it is a
> built-in, in-process admission plugin (GA in 1.36), not a webhook.

**Cleanup**

```sh
kubectl delete -f kubernetes/labs/manifests/mutating-admission-policy.yaml
kubectl delete pod map-test
```

---

## What is CEL? (background for A2, A10, and Phase 3)

**CEL** = **Common Expression Language** — a small, non-Turing-complete expression
language created by Google. Kubernetes embeds it to let you write **policy and
validation logic inline**, without compiling a webhook or writing Go.

**Key properties**
- **Declarative, not imperative** — you write an *expression that evaluates to a
  value*, not a sequence of statements. There is **no assignment** (`=`), no
  loops, no `if/else` statements. This is exactly why
  `Object.metadata.labels["x"] = "y"` failed in A2.
- **Side-effect free & terminating** — expressions can't hang or mutate state, so
  they're safe to run inside the API server request path.
- **Typed** — expressions are compiled and type-checked against the object schema
  *before* they're accepted (that's the `compilation failed` error you saw).
- **Bounded cost** — evaluation has a cost budget, preventing runaway expressions.

**Where Kubernetes uses CEL**
| Feature | Use |
|---------|-----|
| `ValidatingAdmissionPolicy` | CEL `validations` — reject invalid objects |
| `MutatingAdmissionPolicy` (A2) | CEL `applyConfiguration` — mutate objects |
| CRD `x-kubernetes-validations` | CEL rules on custom resources |
| `StrictIPCIDRValidation` (A10) | CEL-backed field validation |
| `ManifestBasedAdmissionControlConfig` (Phase 3) | CEL policies from static files |

**CEL vs. a mutating webhook**
| | CEL (`MutatingAdmissionPolicy`) | Webhook |
|---|---|---|
| Runs | In-process in the API server | Separate HTTPS service |
| Deploy | Just a CRD object | Deployment + Service + TLS + cert rotation |
| Latency | Microseconds | Network round-trip |
| Failure mode | `failurePolicy` (Fail/Ignore) | `failurePolicy` + availability risk |

**Reading a CEL expression** — the A2 mutation builds a *new object* rather than
assigning a field:

```cel
Object{                                  // construct a new object
  metadata: Object.metadata{             // typed sub-object
    labels: {"mutated-by": "k8s-1.36-lab"}  // map literal
  }
}
```

Kubernetes merges this constructed object into the incoming request — the
declarative equivalent of "set this label".

> **Mental model:** think of CEL as a **typed, sandboxed spreadsheet formula**
> that the API server evaluates on every matching request.

---

## A3 — In-place Pod Resize (GA) + Pod-level resources (Beta)

**What changed in 1.36** — in-place container resize is **GA**; **pod-level**
CPU/memory resize (`InPlacePodLevelResourcesVerticalScaling`) is **Beta, on by
default**.

**Apply** — `manifests/inplace-resize.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resize-demo
spec:
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "200m"
          memory: "128Mi"
```

```sh
kubectl apply -f kubernetes/labs/manifests/inplace-resize.yaml
kubectl get pod resize-demo -o jsonpath='{.spec.containers[0].resources}'; echo

# resize in place (no restart)
kubectl patch pod resize-demo --subresource resize --type=merge \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"300m","memory":"128Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}}]}}'

kubectl get pod resize-demo -o jsonpath='{.status.containerStatuses[0].resources}'; echo
kubectl get pod resize-demo -o jsonpath='{.status.containerStatuses[0].restartCount}'; echo
```

```text
pod/resize-demo created
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}
pod/resize-demo patched
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"300m","memory":"128Mi"}}
0
```

**Observe** — the **spec** starts at `cpu=100m/200m`, the patch is accepted via
the `resize` subresource, and the **status** reflects the new
`cpu=300m/500m` — with **`restartCount: 0`** (no restart).

**Read the logs** — the kubelet emits resize events:

```sh
kubectl describe pod resize-demo | grep -A5 -i resize
```

```text
  Normal  Scheduled        31s   default-scheduler  Successfully assigned default/resize-demo to k8s-136-worker3
  Normal  Pulled           31s   kubelet            spec.containers{app}: Container image "registry.k8s.io/pause:3.10" already present on machine and can be accessed by the pod
  Normal  Created          31s   kubelet            spec.containers{app}: Container created
  Normal  Started          31s   kubelet            spec.containers{app}: Container started
  Normal  ResizeStarted    13s   kubelet            Pod resize started: {"containers":[{"name":"app","resources":{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"300m","memory":"128Mi"}}}],"generation":2}
  Normal  ResizeCompleted  13s   kubelet            Pod resize completed: {"containers":[{"name":"app","resources":{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"300m","memory":"128Mi"}}}],"generation":2}
```

> **Reading the log:** the kubelet emits **`ResizeStarted`** then
> **`ResizeCompleted`** with `generation: 2` (the second spec revision). The
> container is **never recreated** — no `Killing`/`Created`/`Started` cycle after
> the resize, which is the whole point of in-place resize (GA in 1.36).

**Cleanup** — `kubectl delete pod resize-demo`

---

## A4 — RestartAllContainers (Beta)

**What changed in 1.36** — `RestartAllContainersOnContainerExits` is **Beta, on by
default**. A container can declare `restartPolicyRules` that restart **all**
containers in the pod when it exits with a matching code.

**Apply** — `manifests/restart-all.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restart-all-demo
spec:
  restartPolicy: Never
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
    - name: sidecar
      image: busybox:1.36
      command: ["sh", "-c", "sleep 5; exit 1"]
      restartPolicy: Always
      restartPolicyRules:
        - action: RestartAllContainers
          exitCodes:
            operator: In
            values: [1]
```

> **Gotcha (two validation errors hit while building this lab):**
>
> 1. **A container using `restartPolicyRules` must set its own
>    `restartPolicy`** (it does not inherit the pod-level one):
>    ```text
>    * spec.containers[1].restartPolicy: Required value: must specify restartPolicy when restart rules are used
>    ```
> 2. **`exitCodes.operator` is required** — supported values are `In` / `NotIn`:
>    ```text
>    * spec.containers[1].restartPolicyRules[0].exitCodes.operator: Unsupported value: "": supported values: "In", "NotIn"
>    ```

```sh
kubectl apply -f kubernetes/labs/manifests/restart-all.yaml
kubectl get pod restart-all-demo -w
```

```text
pod/restart-all-demo created
NAME               READY   STATUS              RESTARTS   AGE
restart-all-demo   0/2     ContainerCreating   0          0s
restart-all-demo   0/2     ContainerCreating   0          0s
restart-all-demo   2/2     Running             0          5s
restart-all-demo   1/2     Error               0          10s
restart-all-demo   0/2     RestartingAllContainers   2          12s
restart-all-demo   2/2     Running                   2          12s
restart-all-demo   1/2     Error                     2          18s
```

**Observe** — the sequence is the whole point of the feature:

1. `2/2 Running` — both containers healthy.
2. `1/2 Error` — the **sidecar** exits 1 (after its 5s sleep).
3. **`RestartingAllContainers`** — a **new 1.36 pod status**; the kubelet is
   restarting **every** container in the pod, not just the failed one.
4. `2/2 Running` with **`RESTARTS 2`** — both containers came back together
   (the count is 2 because both `main` and `sidecar` restarted).
5. `1/2 Error` again — the sidecar's 5s timer fires again, so the cycle repeats.

> **Reading the output:** without this feature, only the `sidecar` would restart
> and `main` would keep running. Here `main`'s restart count also increments,
> proving the **whole pod** was restarted. The transient
> `RestartingAllContainers` status is unique to 1.36.

**Read the logs**

```sh
kubectl describe pod restart-all-demo | grep -A10 -i restart
kubectl logs restart-all-demo -c main --previous
```

**Cleanup** — `kubectl delete pod restart-all-demo`

---

## A5 — NodeLogQuery (GA)

**What changed in 1.36** — `NodeLogQuery` is **GA**. You can query kubelet/system
logs through the API without SSH.

```sh
NODE=k8s-136-worker
kubectl get --raw "/api/v1/nodes/$NODE/proxy/logs/?query=kubelet&since=5m" | head -40
kubectl get --raw "/api/v1/nodes/$NODE/proxy/logs/?query=containerd" | tail -20
```

**Observed (kind default) — the query is IGNORED:**

```html
<!doctype html>
<meta name="viewport" content="width=device-width">
<pre>
<a href="alternatives.log">alternatives.log</a>
<a href="containers/">containers/</a>
<a href="pods/">pods/</a>
</pre>
```

**What this means** — instead of running a log query, the endpoint returned a
**directory listing of `/var/log/`**. The `?query=` parameter had no effect.

> **Gotcha: the `NodeLogQuery` feature gate being GA is NOT sufficient.** The
> kubelet must also have **`enableSystemLogQuery: true`** in its
> `KubeletConfiguration`. Without it, the `/logs/` endpoint falls back to the
> legacy file-serving handler (hence the HTML directory listing). kind does not
> set this by default.

**Fix** — enable it via a `KubeletConfiguration` patch in the kind cluster config
(see `../kind-v1.36-cluster.yaml`, which now includes this patch with a full
explanation):

```yaml
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        apiVersion: kubelet.config.k8s.io/v1beta1
        enableSystemLogQuery: true
```

> **kind limitation:** kubeadm only reads `KubeletConfiguration` from the **first**
> node, so this applies cluster-wide. Recreate the cluster to apply it:
> `kind delete cluster --name k8s-136 && kind create cluster --name k8s-136 --config kubernetes/kind-v1.36-cluster.yaml`

**Once enabled**, the same command returns real log lines:

```sh
kubectl get --raw "/api/v1/nodes/$NODE/proxy/logs/?query=kubelet&since=5m" | head -40
```

```text
Oct 02 00:19:22.998335 k8s-136-worker systemd[1]: kubelet.service - kubelet: The Kubernetes Node Agent skipped, unmet condition check ConditionPathExists=/var/lib/kubelet/config.yaml
Oct 02 00:19:40.564875 k8s-136-worker systemd[1]: Starting kubelet.service - kubelet: The Kubernetes Node Agent...
Oct 02 00:19:40.585516 k8s-136-worker systemd[1]: Started kubelet.service - kubelet: The Kubernetes Node Agent.
Oct 02 00:19:40.604766 k8s-136-worker kubelet[242]: Flag --system-reserved has been deprecated, This parameter should be set via the config file specified by the Kubelet's --config flag. See https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/ for more information.
Oct 02 00:19:40.604766 k8s-136-worker kubelet[242]: Flag --eviction-hard has been deprecated, This parameter should be set via the config file specified by the Kubelet's --config flag. See https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/ for more information.
Oct 02 00:19:40.752398 k8s-136-worker kubelet[242]: I1002 00:19:40.752329     242 server.go:545] "Kubelet version" kubeletVersion="v1.36.4"
Oct 02 00:19:40.752398 k8s-136-worker kubelet[242]: I1002 00:19:40.752351     242 server.go:547] "Golang settings" GOGC="" GOMAXPROCS="" GOTRACEBACK=""
Oct 02 00:19:40.752398 k8s-136-worker kubelet[242]: I1002 00:19:40.752359     242 watchdog_linux.go:94] "Systemd watchdog is not enabled"
```

**Observe** — real kubelet log lines (systemd + kubelet) streamed through the API
server proxy, **no SSH required**. The `?query=kubelet&since=5m` parameters are now
honored.

> **Bonus finding in the logs:** the kubelet warns that `--system-reserved` and
> `--eviction-hard` are **deprecated as flags** and should move into the
> `KubeletConfiguration` file. Our cluster config sets them via
> `kubeletExtraArgs` (flags), which still works but emits these warnings. A future
> cleanup would move them into the `KubeletConfiguration` patch alongside
> `enableSystemLogQuery`.

**Cleanup** — none. A5 is **read-only** (it only queries logs via the API); it
creates no cluster resources.

---

## A6 — KubeletPSI (GA)

**What changed in 1.36** — `KubeletPSI` is **GA**. The kubelet exposes Linux
**Pressure Stall Information** (CPU/memory/IO contention) via the **Summary API**.

```sh
NODE=k8s-136-worker
kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics/resource" | grep -i pressure | head -20
```

**Observed — `/metrics/resource` has NO pressure metrics:**

```text
(no output)
```

> **Gotcha: PSI is NOT in `/metrics/resource`.** Despite the feature being called
> "KubeletPSI", the data is exposed through the **Summary API**
> (`/stats/summary`), not the resource-metrics endpoint. Grepping
> `/metrics/resource` for `pressure` returns nothing.

**Where PSI actually lives** — the Summary API, under `.psi` on each resource:

```sh
kubectl get --raw "/api/v1/nodes/$NODE/proxy/stats/summary" | python3 -c "
import sys,json
d=json.load(sys.stdin)
def walk(o, path=''):
    if isinstance(o, dict):
        for k,v in o.items():
            if k == 'psi' and v:
                print(path + '.psi =', json.dumps(v))
            walk(v, path + '.' + k)
    elif isinstance(o, list):
        for i,v in enumerate(o):
            walk(v, path + f'[{i}]')
walk(d)
" | head -20
```

```text
.node.cpu.psi = {"full": {"total": 130421, "avg10": 0, "avg60": 0, "avg300": 0}, "some": {"total": 166771, "avg10": 0, "avg60": 0, "avg300": 0}}
.node.memory.psi = {"full": {"total": 0, "avg10": 0, "avg60": 0, "avg300": 0}, "some": {"total": 0, "avg10": 0, "avg60": 0, "avg300": 0}}
.node.io.psi = {"full": {"total": 7852, "avg10": 0, "avg60": 0, "avg300": 0}, "some": {"total": 8302, "avg10": 0, "avg60": 0, "avg300": 0}}
.node.systemContainers[0].cpu.psi = {"full": {"total": 67678, ...}, "some": {"total": 74700, ...}}
.node.systemContainers[0].io.psi = {"full": {"total": 349, ...}, "some": {"total": 389, ...}}
.pods[0].cpu.psi = {"full": {"total": 2630, ...}, "some": {"total": 4730, ...}}
.pods[0].containers[0].cpu.psi = {"full": {"total": 2573, ...}, "some": {"total": 4659, ...}}
```

**Observe** — PSI appears at **three levels**, each with `cpu`/`memory`/`io`:

| Level | Path |
|-------|------|
| Node | `.node.{cpu,memory,io}.psi` |
| System containers | `.node.systemContainers[*].{cpu,memory,io}.psi` |
| Pod | `.pods[*].{cpu,memory,io}.psi` |
| Container | `.pods[*].containers[*].{cpu,memory,io}.psi` |

Each block has **`some`** (at least one task stalled) and **`full`** (all tasks
stalled), with `avg10`/`avg60`/`avg300` (percent over 10s/60s/300s) and `total`
(cumulative microseconds).

> **Reading the values:** `avg10=0` with a non-zero `total` means the node has
> accumulated some stall time historically but is **not currently** under
> pressure. To see non-zero averages, drive sustained load (the `stress` pod
> below) and re-read.

**Prerequisite check** — PSI requires kernel support + cgroup v2:

```sh
docker exec k8s-136-worker cat /proc/pressure/cpu
docker exec k8s-136-worker stat -fc %T /sys/fs/cgroup
```

```text
some avg10=0.00 avg60=0.06 avg300=0.08 total=8761148
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
cgroup2fs
```

> **Confirmed:** the kind node kernel exposes `/proc/pressure/*` and uses
> **cgroup v2** (`cgroup2fs`), so PSI is fully supported.

**Drive load and re-read:**

```sh
kubectl run stress --image=busybox:1.36 --restart=Never -- sh -c "while true; do :; done"
sleep 5
kubectl get --raw "/api/v1/nodes/$NODE/proxy/stats/summary" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('node.cpu.psi:', json.dumps(d['node']['cpu']['psi']))
"
kubectl delete pod stress
```

**Cleanup** — `kubectl delete pod stress` (if still present). Otherwise A6 is
read-only.

---

## A7 — flagz / statusz (Beta)

**What changed in 1.36** — `ComponentFlagz`/`ComponentStatusz` are **Beta**;
`config.k8s.io/flagz` and `statusz` are **v1beta1**. These endpoints expose the
effective flags and component status.

```sh
NODE=k8s-136-worker
kubectl get --raw "/api/v1/nodes/$NODE/proxy/flagz" | head -40
kubectl get --raw "/api/v1/nodes/$NODE/proxy/statusz" | head -40
```

**Observed — `flagz` works, `statusz` is Forbidden:**

```text
kubelet flagz
Warning: This endpoint is not meant to be machine parseable, has no formatting compatibility guarantees and is for debugging purposes only.
address=0.0.0.0
allowed-unsafe-sysctls=[]
anonymous-auth=true
application-metrics-count-limit=100
authentication-token-webhook=false
authentication-token-webhook-cache-ttl=2m0s
authorization-mode=AlwaysAllow
authorization-webhook-cache-authorized-ttl=5m0s
authorization-webhook-cache-unauthorized-ttl=30s
boot-id-file=/proc/sys/kernel/random/boot_id
bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf
cert-dir=/var/lib/kubelet/pki
cgroup-driver=cgroupfs
cgroup-root=
cgroups-per-qos=true
client-ca-file=
cloud-provider=
cluster-dns=[]
cluster-domain=
config=/var/lib/kubelet/config.yaml
config-dir=
container-hints=/etc/cadvisor/container_hints.json
container-log-max-files=5
container-log-max-size=10Mi
container-runtime-endpoint=unix:///run/containerd/containerd.sock
containerd=/run/containerd/containerd.sock
containerd-namespace=k8s.io
contention-profiling=false
cpu-cfs-quota=true
cpu-cfs-quota-period=100ms
cpu-manager-policy=none
cpu-manager-policy-options=
cpu-manager-reconcile-period=10s
enable-controller-attach-detach=true
enable-debugging-handlers=true
enable-load-reader=false
enable-server=true
```

```text
Error from server (Forbidden): Forbidden (user=kube-apiserver-kubelet-client, verb=get, resource=nodes, subresource(s)=[statusz])
```

**Observe**
- **`flagz` works** — returns the kubelet's effective flags (note the header
  `kubelet flagz` and the "not machine parseable" warning).
- **`statusz` is Forbidden** — the API server's kubelet client
  (`kube-apiserver-kubelet-client`) lacks RBAC for the `statusz` subresource.

> **Gotcha 1: `statusz` needs RBAC.** The `nodes/statusz` subresource is not
> granted to the kubelet client by default. Grant it with a ClusterRole:
>
> ```sh
> kubectl create clusterrole kubelet-statusz-reader \
>   --verb=get --resource=nodes/statusz
> kubectl create clusterrolebinding kubelet-statusz-reader \
>   --clusterrole=kubelet-statusz-reader \
>   --user=kube-apiserver-kubelet-client
> ```
>
> (Then re-run the `statusz` command.)

> **Gotcha 2: `flagz` shows FLAGS, not feature gates.** Grepping `flagz` for a
> feature-gate name returns nothing because gates are not listed as individual
> lines — they appear inside a single `feature-gates=` flag value. Grep for that
> instead:
>
> ```sh
> kubectl get --raw "/api/v1/nodes/$NODE/proxy/flagz" | grep -o 'feature-gates=[^ ]*' | tr ',' '\n' | grep -i -E "InPlacePodLevel|RestartAllContainers|NodeLogQuery"
> ```

**Cleanup** — none (read-only). If you created the `statusz` RBAC above, remove it:

```sh
kubectl delete clusterrolebinding kubelet-statusz-reader
kubectl delete clusterrole kubelet-statusz-reader
```

---

## A8 — ImageVolume (GA)

**What changed in 1.36** — `ImageVolume` is **stable**. Mount an OCI image's
contents directly as a volume.

**Apply** — `manifests/image-volume.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-volume-demo
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /data && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      image:
        reference: busybox:1.36
        pullPolicy: IfNotPresent
```

```sh
kubectl apply -f manifests/image-volume.yaml
kubectl logs image-volume-demo
```

```text
total 52
drwxr-xr-x    1 root     root          4096 Oct  2 00:25 .
drwxr-xr-x    1 root     root          4096 Oct  2 00:25 ..
drwxr-xr-x    2 root     root         12288 May 18  2023 bin
drwxr-xr-x    2 root     root          4096 May 18  2023 dev
drwxr-xr-x    3 root     root          4096 May 18  2023 etc
drwxr-xr-x    2 nobody   nobody        4096 May 18  2023 home
drwxr-xr-x    2 root     root          4096 May 18  2023 lib
lrwxrwxrwx    1 root     root             3 May 18  2023 lib64 -> lib
drwx------    2 root     root          4096 May 18  2023 root
drwxrwxrwt    2 root     root          4096 May 18  2023 tmp
drwxr-xr-x    4 root     root          4096 May 18  2023 usr
drwxr-xr-x    4 root     root          4096 May 18  2023 var
```

**Observe** — the **busybox image's root filesystem** is mounted at `/data`
(`bin`, `etc`, `lib`, `usr`, `var`, …). No `emptyDir`, no hostPath, no PVC — the
volume *is* an OCI image.

> **Gotcha: the first `kubectl logs` can fail with `ContainerCreating`.** The
> `image` volume must be pulled before the container starts, so an immediate
> `logs` returns:
> ```text
> Error from server (BadRequest): container "app" in pod "image-volume-demo" is waiting to start: ContainerCreating
> ```
> Wait for `Running` (`kubectl get pod image-volume-demo -w`) and retry.

**Confirm the volume type** — `describe` shows it explicitly:

```sh
kubectl describe pod image-volume-demo | grep -A5 -i -E "image|volume"
```

```text
Volumes:
  data:
    Type:        Image (a container image or OCI artifact)
    Reference:   busybox:1.36
    PullPolicy:  IfNotPresent
```

> **Reading the output:** `Type: Image (a container image or OCI artifact)` is the
> GA `ImageVolume` feature. The kubelet pulls the image and bind-mounts its
> filesystem read-only into the pod.

**Cleanup** — `kubectl delete pod image-volume-demo`

---

## A9 — UserNamespaces (GA) & ProcMountType (GA)

**What changed in 1.36** — `UserNamespacesSupport` and `ProcMountType` are **GA**.

**Apply** — `manifests/userns-procmount.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-demo
spec:
  hostUsers: false          # run in a user namespace
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "id; sleep 3600"]
      securityContext:
        procMount: Unmasked  # ProcMountType
```

```sh
kubectl apply -f manifests/userns-procmount.yaml
kubectl logs userns-demo
kubectl exec userns-demo -- id
kubectl exec userns-demo -- cat /proc/self/uid_map
kubectl get pod userns-demo -o jsonpath='{.spec.containers[0].securityContext.procMount}'; echo
```

```text
uid=0(root) gid=0(root) groups=0(root),10(wheel)
uid=0(root) gid=0(root) groups=0(root),10(wheel)
         0 4194697216      65536
Unmasked
```

**Observe** — the container *thinks* it is `root` (`uid=0`), but the **`uid_map`
proves it is not host root**:

```text
         0 4194697216      65536
         │      │            └── length: 65536 UIDs mapped
         │      └─────────────── host UID that namespace-UID 0 maps to
         └────────────────────── namespace UID 0 (what the container sees)
```

> **Reading `uid_map`:** the format is `namespace-uid  host-uid  count`. Here,
> namespace UID `0` maps to host UID **`4194697216`** — a high, unprivileged UID.
> So even though `id` reports `root`, the process has **no host root privileges**.
> That is the whole point of `hostUsers: false` (UserNamespacesSupport, GA in 1.36).

**Confirm the two features:**

```sh
kubectl get pod userns-demo -o jsonpath='{.spec.hostUsers}'; echo
kubectl get pod userns-demo -o jsonpath='{.spec.containers[0].securityContext.procMount}'; echo
```

```text
false
Unmasked
```

- **`hostUsers: false`** — the pod runs in a user namespace (GA).
- **`procMount: Unmasked`** — the container gets an unmasked `/proc` (ProcMountType, GA).

> **Gotcha: the first `kubectl logs` can fail with `ContainerCreating`.** The
> image pull takes a few seconds; wait for `Running` and retry. The pod events
> show the normal `Pulling → Pulled → Created → Started` sequence.

**Prerequisite check** — user namespaces need kernel + runtime support:

```sh
docker exec k8s-136-worker2 cat /proc/sys/user/max_user_namespaces
kubectl get node k8s-136-worker2 -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'; echo
```

```text
79879
containerd://2.3.4
```

> **Confirmed:** the kind node kernel allows user namespaces
> (`max_user_namespaces=79879`) and containerd 2.3.4 supports them.

**Cleanup** — `kubectl delete pod userns-demo`

---

## A10 — Validation changes

**What changed in 1.36**
- `RelaxedServiceNameValidation` (**Beta, on**) — service names may start with a digit.
- `StrictIPCIDRValidation` (**on by default**) — rejects IPs/CIDRs with leading
  zeros or ambiguous masks.

```sh
# Relaxed service name: starts with a digit -> now allowed
kubectl create service clusterip 1st-service --tcp=80:80

# Strict IP/CIDR: leading zeros -> rejected
kubectl run bad-ip --image=nginx --dry-run=server -o yaml \
  --overrides='{"spec":{"hostAliases":[{"ip":"010.000.000.005","hostnames":["x"]}]}}'
```

```text
service/1st-service created
The Pod "bad-ip" is invalid: spec.hostAliases[0].ip: Invalid value: "010.000.000.005": must not have leading 0s
```

**Observe**
- **`service/1st-service created`** — a Service name starting with a digit is now
  accepted (`RelaxedServiceNameValidation`, Beta, on by default). Before 1.36 this
  was rejected.
- **`must not have leading 0s`** — the pod with `010.000.000.005` is **rejected**
  (`StrictIPCIDRValidation`, on by default). The ambiguous leading-zero form is no
  longer allowed; use `10.0.0.5`.

> **Why it matters:** `010.000.000.005` is ambiguous — some parsers read it as
> **octal** (`8.0.0.5`), others as decimal. Strict validation removes that
> ambiguity, closing a class of security/config bugs.

**Cleanup** — `kubectl delete svc 1st-service`

---

## Phase 1 complete ✅

All ten labs run against the `k8s-136` cluster. Summary of what each proved:

| Lab | Feature | Result |
|-----|---------|--------|
| A1 | CLI improvements | arch in `KERNEL-VERSION`, `explain -R`, multi-condition `wait`, container-name suggestions |
| A2 | MutatingAdmissionPolicy (GA) | CEL injected a label, no webhook |
| A3 | In-place resize (GA) | spec→status updated, `restartCount: 0` |
| A4 | RestartAllContainers (Beta) | new `RestartingAllContainers` status, both containers restarted |
| A5 | NodeLogQuery (GA) | kubelet logs via API (after enabling `enableSystemLogQuery`) |
| A6 | KubeletPSI (GA) | PSI in Summary API at 4 levels |
| A7 | flagz/statusz (Beta) | `flagz` works; `statusz` needs RBAC |
| A8 | ImageVolume (GA) | OCI image mounted at `/data` |
| A9 | UserNamespaces/ProcMountType (GA) | `uid_map` proves non-root host mapping |
| A10 | Validation changes | digit-leading service allowed; leading-zero IP rejected |

**Next:** Phase 2 (alpha feature gates) — see
[`phase-b-alpha-feature-gates.md`](./phase-b-alpha-feature-gates.md).

---

## Phase 1 checklist

- [x] A1 CLI tour
- [x] A2 MutatingAdmissionPolicy
- [x] A3 In-place resize
- [ ] A4 RestartAllContainers
- [x] A5 NodeLogQuery
- [x] A6 KubeletPSI
- [x] A7 flagz / statusz
- [x] A8 ImageVolume
- [x] A9 UserNamespaces / ProcMountType
- [x] A10 Validation changes
