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

$ apk add openbao
WARNING: Permanently redirected to https://alpinelinux.org:443/x86_64/APKINDEX.tar.gz
WARNING: updating and opening http://alpinelinux.org/x86_64/APKINDEX.tar.gz: HTTP 404: Not Found
(1/2) Installing openbao (2.5.5-r0)
  Executing openbao-2.5.5-r0.pre-install
(2/2) Installing openbao-openrc (2.5.5-r0)
Executing busybox-1.37.0-r31.trigger
OK: 312.0 MiB in 62 packages

# Check bau installation

$ bao -h
Usage: bao <command> [args]

Common commands:
    read        Read data and retrieves secrets
    write       Write data, configuration, and secrets
    delete      Delete secrets and configuration
```

### Openbao Status

When I restarted openbau system and trying to check bao status, I got connection refused error

```sh

$ bao status
Error checking seal status: Get "https://127.0.0.1:8200/v1/sys/seal-status": dial tcp 127.0.0.1:8200: connect: connection refused

$ cat /var/log/messages | grep bao
# No results returned

# Start the service as it is not started automatically
$ rc-service openbao start
 * /var/log/openbao.log: creating file
 * /var/log/openbao.log: correcting owner
 * Starting OpenBao server ...

# check logs
$ cat /var/log/messages | grep bao
Jul 10 07:28:25 openbau daemon.info supervise-daemon[2344]: Supervisor command line: supervise-daemon openbao --start --stdout /var/log/openbao.log --stderr /var/log/openbao.log --respawn-delay 10 --respawn-max 0 --respawn-period 1800 --user openbao:openbao /usr/bin/bao -- server -config=/etc/openbao.hcl
Jul 10 07:28:25 openbau daemon.info supervise-daemon[2346]: Child command line: /usr/bin/bao server -config=/etc/openbao.hcl
```

### Configure OpenBao SSH Secrets Engine

```sh

$ bao secrets enable -path=ssh-client-signer ssh
Error enabling: Post "https://127.0.0.1:8200/v1/sys/mounts/ssh-client-signer": http: server gave HTTP response to HTTPS client

$ export BAO_ADDR=http://127.0.0.1:8200

$ bao secrets enable -path=ssh-client-signer ssh
Error enabling: Error making API request.

URL: POST http://127.0.0.1:8200/v1/sys/mounts/ssh-client-signer
Code: 503. Errors:

* Vault is sealed

$ bao status | grep -i unseal
Unseal Progress    0/0
Unseal Nonce       n/a

# Missed initializing openbao, start initialization

$ bao operator init

$ bao operator unseal

$ bao status | grep -i unseal
Unseal Progress    1/3

# After repeating above step twice, bao is unsealed

$ bao status | grep -i unseal
# No results returned

$ bao login
Success! You are now authenticated.

$ bao secrets enable -path=ssh-client-signer ssh
Success! Enabled the ssh secrets engine at: ssh-client-signer/
```

When the VM is restarted the service status is stopped. To start openbao on startup, below steps are followed

```sh
$ apk add openbao-openrc

$ rc-update add openbao default
 * service openbao added to runlevel default

$ rc-service openbao start
 * WARNING: openbao has already been started
```

After rebooting the VM, openbao is started at startup. Another note is that we have to set `BAO_ADDR` env variable before performing any bao checks

```sh

$ bao write ssh-client-signer/config/ca generate_signing_key=true
Key            Value
---            -----
issuer_id      c967d296-b34e-41a2
issuer_name    n/a
public_key     ssh-rsa

$ curl -o /etc/ssh/trusted-user-ca-keys.pem http://127.0.0.1:8200/v1/ssh-client-signer/public_key

$ cat /etc/ssh/trusted-user-ca-keys.pem

ssh-rsa AAA

$ bao read -field=public_key ssh-client-signer/config/ca > /etc/ssh/trusted-user-ca-keys.pem

$ vi /etc/ssh/sshd_config
 
$ cat /etc/ssh/sshd_config | grep TrustedUserCAKeys
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem

$ rc-service sshd restart

$ bao write ssh-client-signer/roles/signing-role -<<"EOH"
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "allowed_extensions": "permit-pty,permit-port-forwarding",
  "default_extensions": {
    "permit-pty": ""
  },
  "key_type": "ca",
  "default_user": "gopi",
  "ttl": "30m0s"
}
EOH

# Success! Data written to: ssh-client-signer/roles/signing-role

$ ssh-keygen -t rsa -C "gopi@test.com"

$ bao write ssh-client-signer/sign/signing-role public_key=@$HOME/.ssh/id_rsa.pub

$ bao write -field=signed_key ssh-client-signer/sign/signing-role public_key=@$HOME/.ssh/id_rsa.pub > signed-cert.pub

$ ssh-keygen -Lf signed-cert.pub

Type: ssh-rsa-cert-v01@openssh.com user certificate
Public key: RSA-CERT SHA256:DsqFB59m/D1IqBYhGq2ZKEfH5fb6jQ
Signing CA: RSA SHA256:NJ/PxuqRuN7Z8jjOKhljC8ZJUkGg (using rsa-sha2-256)
Key ID: "vault-root-0eca850797d4b1e630a158846ab664a11f1f97dbea34"
Serial: 16920489170949
Valid: from 2026-07-18T18:44:14 to 2026-07-18T19:14:44
Principals:
        alpine
Critical Options: (none)
Extensions:
        permit-pty

```

### Learning

- Openbao starts in sealed manner everytime the VM gets restarted
- Openbao service is exposed internally on port 8200 on localhost

### Reference

- [Signed SSH Certificates](https://openbao.org/docs/secrets/ssh/signed-ssh-certificates/)