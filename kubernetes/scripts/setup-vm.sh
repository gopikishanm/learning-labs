#!/bin/bash

# Setup k3s-cp-1
qm clone 9000 300 --name k3s-cp-1
qm set 300 --ipconfig0 ip=192.168.1.150/24,gw=192.168.1.1
qm cloudinit update 300
qm start 300

# Setup k3s-cp-2
qm clone 9000 301 --name k3s-cp-2
qm set 301 --ipconfig0 ip=192.168.1.151/24,gw=192.168.1.1
qm cloudinit update 301
qm start 301

# Setup k3s-cp-3
qm clone 9000 302 --name k3s-cp-3
qm set 302 --ipconfig0 ip=192.168.1.152/24,gw=192.168.1.1
qm cloudinit update 302
qm start 302

# Setup Load Balancer VM
qm clone 9000 400 --name k3s-lb-1
qm set 400 --ipconfig0 ip=192.168.1.160/24,gw=192.168.1.1
qm set 400 --cores 1 --memory 2048
qm cloudinit update 400
qm start 400