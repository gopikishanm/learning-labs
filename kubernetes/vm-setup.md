## VM's Setup

### k3s-cp-1

```sh

# Setup k3s-cp-1
qm clone 9000 300 --name k3s-cp-1
qm set 300 --ipconfig0 ip=192.168.1.150/24,gw=192.168.1.1
qm cloudinit update 300
qm start 300

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

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --ask-become-pass --private-key= --tags k3s


```

### Loadbalancer Setup

```sh

# Setup k3s-lb-1
qm clone 9000 400 --name k3s-lb-1
qm set 400 --ipconfig0 ip=192.168.1.160/24,gw=192.168.1.1
qm cloudinit update 400
qm start 400

# Run from ansible folder

$ ansible-playbook -i inventory/hosts.ini playbooks/k8s-setup.yml --private-key= --tags common


```

### Drop Infra

```sh
$ qm stop 300 && qm destroy 300 # Destroy cp-1 
$ qm destroy 9000 # Destroy template

```
