# Rocky Linux 9 Cloud Image

Automated Rocky Linux 9 QCOW2 cloud image builder for KVM, KubeVirt and OpenStack environments.

The script customizes the official Rocky Linux 9 GenericCloud image offline. It does **not** create or boot a persistent VM on the build host.

## Features

- Uses the official Rocky Linux 9 x86_64 GenericCloud QCOW2 image.
- Verifies the downloaded image against the official SHA256 checksum.
- Preserves the original **10 GiB** virtual disk size (for the source used in the documented build).
- Checks for `cloud-init`, `qemu-guest-agent`, `cloud-utils-growpart`, and OpenSSH server.
- Configures cloud-init with `root` as the default account and allows SSH password authentication.
- Allows direct root SSH login, including SSH-key authentication.
- Removes machine identity, SSH host keys, DHCP lease state and logs before packaging.
- Compresses the QCOW2 output and generates a final SHA256 checksum.

> **Security warning:** Direct root/password SSH login is enabled by design. Use unique strong credentials, network access controls, and anti-brute-force protections. No root password is stored inside the image.

## Requirements

Linux build host with `sudo`, Internet access, and these commands:

```bash
sudo apt-get update
sudo apt-get install -y curl qemu-utils libguestfs-tools
```

Package names can differ on non-Debian hosts. The script also needs `sha256sum` and `awk` (normally included). `libguestfs` must be usable on the build host.

## Build

```bash
cd rocky/9
chmod +x build-rocky9-cloud-image.sh
sudo env WORK_DIR=/opt/images/rocky9 bash ./build-rocky9-cloud-image.sh
```

Default output:

```text
/opt/images/rocky9/rocky-9-cloud.qcow2
/opt/images/rocky9/rocky-9-cloud.qcow2.sha256
```

The script stops rather than overwriting an existing working or output file. An existing original download is re-verified using the current official checksum. If the upstream `latest` image changes, use a clean build directory.

Optional overrides: `WORK_DIR`, `OUTPUT_NAME`, `IMAGE_URL`, and `LIBGUESTFS_BACKEND`.

## Password provisioning

The base image's root password remains locked until a provisioner sets it. **Enabling SSH password authentication does not itself create a usable password.** Supply appropriate per-instance cloud-init user-data, e.g.:

```yaml
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: REPLACE_WITH_UNIQUE_PASSWORD
      type: text
```

Avoid persisting plaintext user-data in logs or repositories. Confirm the provisioning platform actually passes cloud-init metadata to the guest.

## Validation

```bash
qemu-img check /opt/images/rocky9/rocky-9-cloud.qcow2
cd /opt/images/rocky9
sha256sum -c rocky-9-cloud.qcow2.sha256
```

A successful QCOW2 integrity check does **not** verify booting or cloud-init behavior. Before production, launch a test VM and confirm successful boot, IPv4 networking, root password provisioning, SSH access, disk resize on larger volumes, and QEMU Guest Agent connectivity.

## Sources

- [Official Rocky Linux image directory](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/)
- [Cloud-init documentation](https://docs.cloud-init.io/)

## Repository layout

```text
rocky/9/
├── .gitignore
├── README.md
└── build-rocky9-cloud-image.sh
```

Generated QCOW2 disks are not committed to Git.
