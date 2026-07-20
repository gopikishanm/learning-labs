## VM's Setup

### k3s-cp-1

qm clone 9000 300 --name k3s-cp-1
qm set 300 --ipconfig0 ip=192.168.1.150/24,gw=192.168.1.1
qm cloudinit update 300
qm start 300