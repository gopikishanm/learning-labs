# Etcd Quorum Loss Recovery

## Table of Contents

- [What Happened](#what-happened)
- [Timeline of Events](#timeline-of-events)
- [Root Cause Analysis](#root-cause-analysis)
- [Recovery Procedure](#recovery-procedure)
- [Prevention](#prevention)

---

## What Happened

The K3s cluster's embedded etcd lost **quorum** — the minimum number of members needed to reach consensus (majority of 3 = 2 nodes). All three control plane nodes showed `NotReady`, and the Kubernetes API server returned 500 errors with:

```
failed to get etcd MemberList: context deadline exceeded
```

**On cp-1:**
```
dial tcp 192.168.1.151:2380: connect: connection refused
```

**On cp-2 and cp-3:**
```
duplicate node name found, please use a unique name for this node
```

---

## Timeline of Events

### Phase 1: Initial Setup Failures

1. **First Bootstrap** — k3s install on cp-1 failed because `--server` pointed to the load balancer (deadlock). Cp-1 had partial state.

2. **Fix applied** — Removed `--server` from cp-1, added `--tls-san LB_IP`. Cp-1 came up successfully.

3. **Cp-2 and cp-3 installed** — HAProxy had `option httpchk GET /healthz` (HTTP against TLS endpoint), so LB marked backends as DOWN. Cp-2/cp-3 failed to reach the API through the LB.

4. **HAProxy fixed** — Removed HTTP health check, used TCP-only check. LB worked.

5. **Cp-2/cp-3 failed** — Missing `--flannel-backend=none` and `--disable-network-policy` flags caused `critical configuration value mismatch between servers`.

### Phase 2: Destructive Cleanup

6. **Cleanup block added** — A playbook task was added to wipe `/var/lib/rancher/k3s/` on cp-2/cp-3 (including etcd data) and delete the nodes from Kubernetes API on cp-1.

7. **Etcd still had old members** — Deleting from `kubectl` does NOT remove from etcd. Cp-2/cp-3 still existed in etcd's member list on cp-1.

8. **Duplicate node on rejoin** — When cp-2 tried to rejoin, etcd rejected it with `duplicate node name found`. The cleanup wiped cp-2's local data, but cp-1's etcd still had cp-2 registered.

9. **Etcd member remove failed** — A playbook task tried `k3s etcd member remove`, but this subcommand **does not exist** in k3s v1.36+.

### Phase 3: Quorum Loss

10. **Cp-1 loses contact** — With cp-2/cp-3 not running, but still registered as etcd members, cp-1's etcd repeatedly tried to reach them on port 2380, getting `connection refused`.

11. **Elections fail** — etcd needs 2/3 members for quorum. With only cp-1 available, it kept starting elections but could never win (needs 1 more vote).

12. **Deadline exceeded** — After repeated failures, etcd stopped serving entirely. All API calls returned `context deadline exceeded`. All nodes became `NotReady`.

13. **Manual deletion** — The user deleted `/var/lib/rancher/k3s/server/db/etcd/member` on all three CP nodes to start fresh.

---

## Root Cause Analysis

### Direct Cause

The playbook's cleanup block for additional control plane nodes **wiped etcd data** (`/var/lib/rancher/k3s/`) while the etcd cluster still had them as active members. This left cp-1's etcd waiting for dead members to respond, destroying quorum.

### Contributing Factors

1. **`systemctl is-failed` is too narrow** — Only returns exit 0 when service is in `failed` state. A manually-stopped service (`inactive`) is not caught. The cp-1 cleanup block used this check, so even after the user deleted etcd data and stopped k3s, the cleanup didn't trigger.

2. **`k3s etcd` subcommand removed** — k3s v1.36+ removed the `k3s etcd member list` and `k3s etcd member remove` subcommands. The embedded `etcdctl` binary may also be missing, making it impossible to repair etcd membership from the command line.

3. **`creates: /usr/local/bin/k3s` prevents reinstall** — The install task skips if the k3s binary exists. After manual etcd data deletion, the binary was still present, so the playbook never ran the install script again.

4. **`kubectl delete node` ≠ etcd member removal** — Removing a node from Kubernetes API does not remove it from the etcd member list. The node still participates in raft consensus.

---

## Recovery Procedure

### Option A: Full Reset (all nodes) — **SUCCESSFULLY TESTED**

This was the approach used to recover the cluster. It was tested and confirmed working:

```bash
# 1. On each CP node, ensure k3s is fully stopped and data is gone
ssh ubuntu@192.168.1.150 "sudo systemctl stop k3s; sudo rm -rf /var/lib/rancher/k3s"
ssh ubuntu@192.168.1.151 "sudo systemctl stop k3s; sudo rm -rf /var/lib/rancher/k3s"
ssh ubuntu@192.168.1.152 "sudo systemctl stop k3s; sudo rm -rf /var/lib/rancher/k3s"

# 2. Re-run the k3s playbook
ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml \
  --ask-become-pass --private-key=<key-path> --tags k3s
```

**Result:** All three control plane nodes joined successfully. The key fix was using `systemctl cat` + `systemctl is-active` instead of `systemctl is-failed` for the cleanup check — this correctly caught the `inactive (dead)` state after manual etcd data deletion.

The playbook's sequence:
1. **Cp-1** — Detects service exists but inactive → wipes everything → fresh `--cluster-init` install → comes up as new single-node etcd cluster
2. **Cp-2** — Same cleanup → fresh install joins cp-1's new etcd cluster via LB → duplicate node name no longer an issue (no stale etcd members)
3. **Cp-3** — Same as cp-2
4. **Worker** — Clean install via `agent` subcommand

### Option B: Minimal etcd repair (if etcd data still exists)

If /var/lib/rancher/k3s/ still has the etcd directory on at least one node:

```bash
# 1. Find the embedded etcdctl
ETCDCTL=$(sudo find /var/lib/rancher/k3s/data -name etcdctl -type f | head -1)

# 2. Stop k3s on all but cp-1
ssh ubuntu@192.168.1.151 "sudo systemctl stop k3s"
ssh ubuntu@192.168.1.152 "sudo systemctl stop k3s"

# 3. List etcd members from cp-1
sudo $ETCDCTL --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  member list

# 4. Remove the broken members
sudo $ETCDCTL --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  member remove <MEMBER_ID>
```

---

## Prevention

The playbook has been updated to prevent this from happening again:

| Issue | Fix |
|-------|-----|
| Cleanup only caught `failed` state | Changed to `systemctl cat` + `systemctl is-active` — catches all non-running states (inactive, dead, failed) |
| Wiped etcd data on additional CP nodes while cluster had stale members | Now all CP cleanup blocks trigger **together** when cp-1 also needs a fresh install — safe because a new etcd cluster is created with no stale member entries |
| `k3s etcd member remove` doesn't exist in v1.36+ | Removed this task entirely |
| `kubectl delete node` without etcd removal | Removed — doesn't help and creates confusion |
| `creates: /usr/local/bin/k3s` blocks reinstall | Works correctly after cleanup wipes the binary |

### Safety Rule for Wiping Additional CP Nodes

Wiping `/var/lib/rancher/k3s/` on cp-2/cp-3 is **safe ONLY** when cp-1 was also wiped and reinstalled fresh (creating a brand new etcd cluster with no stale member entries). The playbook's cleanup blocks are designed to trigger together in this scenario.

If cp-1 is **healthy** (etcd cluster intact with all 3 members), do NOT wipe cp-2/cp-3 — instead, remove the broken members via `etcdctl` on cp-1 and then rejoin fresh.

### Key Principles for Embedded Etcd

1. **Never** delete `/var/lib/rancher/k3s/` on a single node in a multi-node cluster where other nodes still have valid etcd data — this breaks quorum.
2. If **all** nodes' etcd data is deleted simultaneously and all start fresh, they can form a new cluster safely.
3. To remove a single member, use `etcdctl` (embedded or separate), not `kubectl delete node`.
4. `k3s etcd` subcommand is **not available** in v1.36+ — do not rely on it.