## Setup Openbau

Below configuration was used

OS: Alpine Linux amd64
CPU: 1 Core
Memory: 1GB
Storage: 32 GB

### Setup Alpine

```sh
$ setup-alpine

Using us keyboard layout, Using eth0 interface and let the system get ip address from dhcp.

Using 'sys' for disk and proceed with installation

Setup doas by installing and adding current user to wheel group

# Update /etc/apk/repositories to enable community channel

/home/gopi # apk add openbao
WARNING: Permanently redirected to https://alpinelinux.org:443/x86_64/APKINDEX.tar.gz
WARNING: updating and opening http://alpinelinux.org/x86_64/APKINDEX.tar.gz: HTTP 404: Not Found
(1/2) Installing openbao (2.5.5-r0)
  Executing openbao-2.5.5-r0.pre-install
(2/2) Installing openbao-openrc (2.5.5-r0)
Executing busybox-1.37.0-r31.trigger
OK: 312.0 MiB in 62 packages

# Check bau installation

/home/gopi # bao -h
Usage: bao <command> [args]

Common commands:
    read        Read data and retrieves secrets
    write       Write data, configuration, and secrets
    delete      Delete secrets and configuration
```

The next step is to setup signed ssh certificates - https://openbao.org/docs/secrets/ssh/signed-ssh-certificates/