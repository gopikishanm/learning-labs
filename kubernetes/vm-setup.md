## VM's Setup

### k3s-cp-1

```sh

# Setup k3s-cp-1
qm clone 9000 300 --name k3s-cp-1
qm set 300 --cores 3 --cpulimit 2 --memory 3072 --balloon 2048
qm set 300 --ipconfig0 ip=192.168.1.150/24,gw=192.168.1.1
qm cloudinit update 300
qm start 300

# Setup k3s-cp-2
qm clone 9000 301 --name k3s-cp-2
qm set 301 --cores 3 --cpulimit 2 --memory 3072 --balloon 2048
qm set 301 --ipconfig0 ip=192.168.1.151/24,gw=192.168.1.1
qm cloudinit update 301
qm start 301

# Setup k3s-cp-3
qm clone 9000 302 --name k3s-cp-3
qm set 302 --cores 3 --cpulimit 2 --memory 3072 --balloon 2048
qm set 302 --ipconfig0 ip=192.168.1.152/24,gw=192.168.1.1
qm cloudinit update 302
qm start 302

# Setup k3s-worker-1
qm clone 9000 305 --name k3s-worker-1
qm set 305 --cores 3 --cpulimit 2 --memory 3072 --balloon 2048
qm set 305 --ipconfig0 ip=192.168.1.155/24,gw=192.168.1.1
qm cloudinit update 305
qm start 305


# Check connectivity
ssh -i <private-key> ubuntu@192.168.1.150

# Update ansible/inventory/hosts.ini for cp-1

# Update ansible/group_vars/all.yml for cp-1

# Check ansible connectivity
ansible -i kubernetes/ansible/inventory/hosts.ini all --private-key= -m ping

# Output
k3s-cp-1 | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3.12"
    },
    "changed": false,
    "ping": "pong"
}

## Either remove become or setup host requesting password when becoming sudo
$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --become-method=sudo --extra-vars="ansible_become=false" --tags common

# Got below error

E: Could not create temporary file for /var/lib/apt/extended_states - mkstemp (13: Permission denied)
E: Failed to write temporary StateFile /var/lib/apt/extended_states

# This error is caused by above command where ansible_become is set to false. Privilige escalation is necessary to mark packages as installed.

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --ask-become-pass --private-key= --tags common

# Output
PLAY RECAP ********************************************************************************************************************************************************************************
k3s-cp-1                   : ok=18   changed=11   unreachable=0    failed=0    skipped=0    rescued=0    ignored=0

# Need to setup loadbalancer vm before initializing k3s as it needs load balancer ip

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --ask-become-pass --private-key= --tags loadbalancer

fatal: [k3s-lb-1]: FAILED! =>
    changed: false
    msg: |-
        Unable to restart service haproxy: Job for haproxy.service failed because the control process exited with error code.
        See "systemctl status haproxy.service" and "journalctl -xeu haproxy.service" for details.

# Noticed below errors in logs on the server

Aug 09 05:53:47 k3s-lb-1 haproxy[17601]: [ALERT]    (17601) : config : parsing [/etc/haproxy/haproxy.cfg:22]: Missing LF on last line, file might have been truncated at position 40.
Aug 09 05:53:47 k3s-lb-1 haproxy[17601]: [ALERT]    (17601) : config : Error(s) found in configuration file : /etc/haproxy/haproxy.cfg

# The haproxy config file should have a new line at the end. Updated the haproxy.cfg.j2 and re-ran the playbook

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --ask-become-pass --private-key= --tags k3s

k3s-cp-1 k3s[18771]: time="2026-08-09T06:06:36Z" level=info msg="Starting k3s v1.36.3+k3s1 (5aed4d7b)"
k3s-cp-1 k3s[18771]: time="2026-08-09T06:06:36Z" level=fatal msg="Error: preparing server: failed to bootstrap cluster data: failed to check if bootstrap data has been initialized: failed to validate token: failed to get CA certs: Get \"https://192.168.1.160:6443/cacerts\": EOF"
k3s-cp-1 systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE

ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml \
  --ask-become-pass --private-key= --tags cni-storage

```

### Loadbalancer Setup

```sh

# Setup k3s-lb-1
qm clone 9000 400 --name k3s-lb-1
qm set 400 --cores 3 --cpulimit 2 --memory 3072 --balloon 2048
qm set 400 --ipconfig0 ip=192.168.1.160/24,gw=192.168.1.1
qm cloudinit update 400
qm start 400

# Run from ansible folder

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --private-key= --tags common


```

### k3s Running

```sh
k3s kubectl get nodes
NAME       STATUS   ROLES                AGE     VERSION
k3s-cp-1   Ready    control-plane,etcd   11m     v1.36.3+k3s1
k3s-cp-2   Ready    control-plane,etcd   7m43s   v1.36.3+k3s1
k3s-cp-3   Ready    control-plane,etcd   7m12s   v1.36.3+k3s1
```

### Drop Infra

```sh
qm stop 300 && qm destroy 300 # Destroy cp-1 
qm stop 301 && qm destroy 301 # Destroy cp-2
qm stop 302 && qm destroy 302 # Destroy cp-3 
qm stop 400 && qm destroy 400

qm destroy 9000 # Destroy template

```
