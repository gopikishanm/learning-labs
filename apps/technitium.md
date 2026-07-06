## Setup Technitium DNS as LXC

This guide walks through installing Technitium DNS in a Proxmox LXC container and configuring Alpine Linux to use it as the nameserver.

### Install Technitium DNS

1. Log in to your Proxmox shell.
2. Run the following command to install Technitium DNS inside an LXC container.

For reference, here is the one-liner install script provided by the community:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/technitiumdns.sh)"
```

### Installation Logs

Below are the logs from a successful installation, showing the container creation and setup steps:

```sh
  Missing jq for script status check. Continuing without status verification.
  ⚙️  Using Default Settings on node mini-pc
  💡  PVE Version 9.1.1 (Kernel: 6.17.2-1-pve)
  🆔  Container ID: 103
  🖥️  Operating System: debian (13)
  📦  Container Type: Unprivileged
  💾  Disk Size: 2 GB
  🧠  CPU Cores: 1
  🛠️  RAM Size: 512 MiB
  🚀  Creating a Technitium DNS LXC using the above default settings

  ✔️  Storage space validated
  ...
  ✔️  Template storage 'local' validated
  ✔️  Template search completed
  ✔️  Template debian-13-standard_13.1-2_amd64.tar.zst [online]
  ✔️  Template download successful.
  ✔️  LXC Container 103 was successfully created.
  ✔️  Started LXC Container
  ✔️  Network in LXC is reachable (ping)
  ✔️  Customized LXC Container
  ✔️  Set up Container OS

  🚀  Technitium DNS setup has been successfully initialized!
  💡  Access it using the following URL:
  🌐  http://192.168.z.z:5380
```

### Configure Alpine to Use Technitium as Nameserver

To point Alpine Linux at your new DNS server, you need to update its network configuration. For reference, here are the steps and configuration files involved:

```sh
$ doas sh

$ vi /etc/network/interfaces

$ vi /etc/resolv.conf

# Reboot VM
```

### Add an 'A' Record for Alpine from the Technitium UI

Once the DNS server is running, you can add DNS records through its web interface. Below is a sample log showing a successful record addition:

```sh
#Logs

[2026-07-06 07:56:16 UTC] [192.168.1.115:51966] Check for update was done {dnsServerEnableCheckForUpdate: True; updateAvailable: False; updateVersion: 15.3;}
[2026-07-06 08:00:31 UTC] [192.168.1.115:52135] [admin] New record was added to Primary zone 'gopi.lab' successfully {record: openbau.gopi.lab.     3600      IN  A             192.168.1.10x}
```

### Troubleshooting DNS Resolution on Alpine

After reboot, the changes to `/etc/resolv.conf` were lost. Alpine's network initialization script overrides this file on every boot. To prevent that, I had to set `RESOLV_CONF=no` in the `udhcpc.conf` file and reconfigure the network interface for a static IP.

For reference, here are the configuration changes that resolved the issue:

```sh
$ vi /etc/udhcpc/udhcpc.conf

# Restart networking service
$ rc-service networking restart

# Update /etc/network/interfaces to use static ip

auto eth0
iface eth0 inet static
    address 192.168.z.z
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 192.168.1.zz
```

### Verify DNS Resolution with nslookup

After applying the configuration changes and rebooting, DNS resolution worked correctly. For reference, here are the results from both the Alpine machine and a Mac:

```sh
# From alpine linux box
$ nslookup openbau.gopi.lab 192.168.1.129
Server: 192.168.1.129
Address: 192.168.1.129:53

Name: openbau.gopi.lab
Address: 192.168.1.10x

# From mac

$ nslookup openbau.gopi.lab 192.168.1.129
Server:		192.168.1.129
Address:	192.168.1.129#53

Name:	openbau.gopi.lab
Address: 192.168.1.109
```

#### Clarifications

When using `nslookup`, the order of DNS servers in `/etc/resolv.conf` matters. If the first server fails, resolution moves to the next one. After reordering the nameserver entries, I no longer needed to specify the DNS server in the `nslookup` command.

For reference, here is the output after updating `/etc/resolv.conf`:

```sh
# After updating /etc/resolv.conf

$ nslookup openbau.gopi.lab
Server:		192.168.1.129
Address:	192.168.1.129#53

Name:	openbau.gopi.lab
Address: 192.168.1.109
```
