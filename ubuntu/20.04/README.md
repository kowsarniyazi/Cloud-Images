# Image Cloud

Automated Ubuntu 20.04 QCOW2 cloud image builder for KVM/OpenStack environments.

This repository contains a Bash script that builds a reusable Ubuntu 20.04 cloud image directly from the official Ubuntu cloud image. The build process modifies the disk offline and does **not** require creating a persistent virtual machine on the build host.

## Features

The builder:

- Downloads the official Ubuntu 20.04 cloud image.
- Creates a disposable QCOW2 working copy.
- Resizes the virtual disk to a configurable size.
- Mounts and customizes the image offline with `libguestfs`.
- Installs:
  - `cloud-init`
  - `qemu-guest-agent`
  - `net-tools`
  - `openssh-server`
- Enables root SSH login.
- Enables SSH password authentication.
- Configures cloud-init to allow root/password provisioning.
- Removes cloud-init instance state.
- Clears `/etc/machine-id`.
- Removes SSH host keys so every new VM generates unique keys.
- Restores the standard `systemd-resolved` resolver configuration.
- Validates the effective OpenSSH configuration.
- Verifies QCOW2 integrity before and after processing.
- Creates a compressed and sparse QCOW2 image with `virt-sparsify`.
- Generates and verifies a SHA256 checksum.

## Repository Structure

```text
.
├── build-ubuntu20-cloud-image.sh
└── README.md
```

The generated images are intentionally not stored in Git.

## Requirements

The script is designed for a Debian/Ubuntu-based Linux build host with root access.

Required packages are installed automatically by the script:

```text
qemu-utils
libguestfs-tools
wget
ca-certificates
lsof
python3
```

The build host must also have:

- Internet access to Ubuntu repositories.
- Enough free disk space for the source, working, temporary, and final images.
- KVM support is recommended for faster `libguestfs` operations, but the script can fall back to software emulation depending on the host configuration.

## Usage

Make the script executable:

```bash
chmod +x build-ubuntu20-cloud-image.sh
```

Run it as root:

```bash
sudo ./build-ubuntu20-cloud-image.sh
```

The default build directory is:

```text
/opt/images/ubuntu20
```

The default final output is:

```text
/opt/images/ubuntu20/ubuntu-20.04-cloud.qcow2
/opt/images/ubuntu20/ubuntu-20.04-cloud.qcow2.sha256
```

## Configuration

The script supports environment-variable overrides.

### Custom build directory

```bash
sudo -E WORKDIR=/data/images/ubuntu20 ./build-ubuntu20-cloud-image.sh
```

### Custom virtual disk size

```bash
sudo -E VIRTUAL_SIZE=30G ./build-ubuntu20-cloud-image.sh
```

### Custom temporary directory

Use a filesystem with sufficient free space for `virt-sparsify`:

```bash
sudo -E TMPDIR_BUILD=/data/tmp ./build-ubuntu20-cloud-image.sh
```

### Rebuild and overwrite an existing final image

```bash
sudo -E FORCE=1 ./build-ubuntu20-cloud-image.sh
```

### Multiple overrides

```bash
sudo -E \
  WORKDIR=/data/images/ubuntu20 \
  TMPDIR_BUILD=/data/tmp \
  VIRTUAL_SIZE=30G \
  FORCE=1 \
  ./build-ubuntu20-cloud-image.sh
```

## Build Workflow

The script follows this process:

```text
Official Ubuntu 20.04 Cloud Image
            |
            v
     Working QCOW2 Copy
            |
            v
      Resize Virtual Disk
            |
            v
    Mount with libguestfs
            |
            v
 Install Cloud/Guest Packages
            |
            v
 Configure SSH + cloud-init
            |
            v
 Remove Machine-Specific State
            |
            v
      Cleanly Unmount
            |
            v
       qemu-img check
            |
            v
      virt-sparsify
            |
            v
   Final Compressed QCOW2
            |
            v
      SHA256 Validation
```

## SSH and Cloud-init Configuration

The image contains the following SSH override:

```text
/etc/ssh/sshd_config.d/00-cloud-image.conf
```

with:

```text
PermitRootLogin yes
PasswordAuthentication yes
```

The image also contains:

```text
/etc/cloud/cloud.cfg.d/99-cloud-image.cfg
```

with:

```yaml
disable_root: false
ssh_pwauth: true
```

The image does **not** contain a fixed root password. Credentials should be injected by the destination cloud platform through cloud-init.

## QEMU Guest Agent

`qemu-guest-agent` is installed inside the generated image.

For OpenStack, make sure the image or instance is configured to expose the QEMU guest-agent VirtIO channel. A commonly used Glance image property is:

```text
hw_qemu_guest_agent=yes
```

Example:

```bash
openstack image set \
  --property hw_qemu_guest_agent=yes \
  ubuntu-20.04-cloud
```

## Example OpenStack Upload

```bash
openstack image create "Ubuntu 20.04 Cloud" \
  --file ubuntu-20.04-cloud.qcow2 \
  --disk-format qcow2 \
  --container-format bare \
  --property os_distro=ubuntu \
  --property os_version=20.04 \
  --property hw_qemu_guest_agent=yes
```

After uploading, create a test instance and verify:

```bash
cloud-init status
systemctl status qemu-guest-agent
cat /etc/machine-id
```

Also verify that SSH access and cloud-init credential injection work as expected.

## Integrity Verification

A SHA256 checksum is generated automatically.

Verify it with:

```bash
sha256sum -c ubuntu-20.04-cloud.qcow2.sha256
```

Expected result:

```text
ubuntu-20.04-cloud.qcow2: OK
```

## Important Notes

### Do not commit generated images

QCOW2, IMG, ISO, and other generated disk-image files can be very large and should not be committed to this repository.

A recommended `.gitignore` includes:

```gitignore
*.qcow2
*.img
*.iso
*.raw
*.sha256
```

### Keep the working image until testing is complete

The script keeps the working QCOW2 image after the build. Do not delete it until the final image has been successfully boot-tested on the destination cloud platform.

### Root password authentication

This project deliberately enables root SSH login and password authentication for cloud provisioning scenarios. Evaluate this configuration against your own security requirements before using the image in production.

For stronger security, prefer SSH key authentication and restrict password-based root access whenever possible.

## Troubleshooting

### `virt-sparsify` reports insufficient `/tmp` space

Use a different temporary directory located on a filesystem with more free space:

```bash
sudo -E TMPDIR_BUILD=/path/with/free/space ./build-ubuntu20-cloud-image.sh
```

### The QCOW2 image is locked

Check which process is using it:

```bash
lsof /path/to/ubuntu20-working.qcow2
```

Do not forcibly terminate a QEMU process until you have confirmed that it belongs to a stale `libguestfs` appliance and the image is no longer mounted.

### DNS fails during package installation

The script temporarily copies the build host's resolver configuration into the mounted image for package installation, then restores the standard Ubuntu `systemd-resolved` symlink before finalizing the image.

## License

Add a license file that matches how you want others to use this project. For an open-source utility repository, the MIT License is a common permissive option.
