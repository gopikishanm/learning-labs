# Setup Kubernetes using Talos

## Commands Executed

```sh
# On local machine, install talosctl

$ brew install siderolabs/tap/talosctl

# Download ISO

$ mkdir -p _out/
$ curl https://factory.talos.dev/image/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba/v1.13.5/metal-amd64.iso -L -o _out/metal-amd64.iso

# Created custom ISO image which has qemu agent enabled and downloaded the image

# Created a new VM on Proxmox

```

## References

- https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/virtualized-platforms/proxmox