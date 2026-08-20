# Debian 11 Cloud Image

Automated Debian 11 (Bullseye) QCOW2 cloud image builder for KVM/OpenStack environments.

This directory contains a Bash script that builds a reusable Debian 11 cloud image from the official Debian generic cloud image. The image is customized offline with `libguestfs`; no persistent virtual machine is created on the build host.

## Features

The builder:

- Downloads the official Debian 11 generic cloud image.
- Verifies the downloaded image against Debian's published SHA512 checksum.
- Creates a disposable QCOW2 working copy while keeping the source image unchanged.
- Preserves the original virtual disk size; no resize operation is performed.
- Mounts and customizes the image offline with `libguestfs`.
- Uses the build host's resolver configuration temporarily during package installation and restores Debian's original `resolv.conf` afterward.
- Installs `qemu-guest-agent`.
- Verifies that `cloud-init`, `cloud-guest-utils`, and `openssh-server` are present.
- Enables root SSH login and SSH password authentication.
- Configures cloud-init for root/password provisioning.
- Validates the effective OpenSSH configuration with a temporary host key.
- Runs `virt-sysprep` to remove machine-specific state.
- Performs a final cleanup after `virt-sysprep` because sysprep can recreate `/etc/machine-id`.
- Clears `/etc/machine-id`.
- Removes SSH host keys so every new VM generates unique keys.
- Removes cloud-init instance state and logs.
- Verifies QCOW2 integrity during the build.
- Creates a compressed, sparse QCOW2 image with `virt-sparsify`.
- Generates and verifies a SHA256 checksum for the final image.

## Repository Structure

```text
Debian-11/
├── .gitignore
├── README.md
└── build-debian11-cloud-image.sh
```

Generated disk images are intentionally not stored in Git.

## Requirements

The script is intended to run as `root` on a Debian/Ubuntu-based Linux build host.

The following build-host packages are installed automatically:

```text
qemu-utils
libguestfs-tools
wget
ca-certificates
lsof
python3
```

The build host also needs:

- Internet access to `cloud.debian.org`, `deb.debian.org`, and Debian security repositories.
- Enough free disk space for the source, working, temporary, and final images.
- KVM support is recommended for faster libguestfs operations.

## Usage

Make the script executable:

```bash
chmod +x build-debian11-cloud-image.sh
```

Run it as root:

```bash
sudo ./build-debian11-cloud-image.sh
```

The default build directory is:

```text
/opt/images/debian11
```

The default final output is:

```text
/opt/images/debian11/debian-11-cloud.qcow2
/opt/images/debian11/debian-11-cloud.qcow2.sha256
```

## Configuration

The script supports environment-variable overrides.

### Custom build directory

```bash
sudo -E WORKDIR=/data/images/debian11 ./build-debian11-cloud-image.sh
```

### Custom temporary directory

```bash
sudo -E TMPDIR_BUILD=/data/tmp ./build-debian11-cloud-image.sh
```

### Custom mount point

```bash
sudo -E MOUNTPOINT=/mnt/debian11-custom ./build-debian11-cloud-image.sh
```

### Rebuild and overwrite an existing final image

```bash
sudo -E FORCE=1 ./build-debian11-cloud-image.sh
```

### Multiple overrides

```bash
sudo -E \
  WORKDIR=/data/images/debian11 \
  TMPDIR_BUILD=/data/tmp \
  MOUNTPOINT=/mnt/debian11-build \
  FORCE=1 \
  ./build-debian11-cloud-image.sh
```

## Build Workflow

```text
Official Debian 11 Generic Cloud Image
                 |
                 v
          SHA512 Validation
                 |
                 v
          Working QCOW2 Copy
                 |
                 v
        Mount with libguestfs
                 |
                 v
      Backup Debian resolv.conf
                 |
                 v
     Temporary Build-Host DNS
                 |
                 v
        Install QEMU Guest Agent
                 |
                 v
      Configure SSH + cloud-init
                 |
                 v
       Restore Debian resolv.conf
                 |
                 v
            Cleanly Unmount
                 |
                 v
            virt-sysprep
                 |
                 v
       Final Machine-State Cleanup
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

## Disk Size

The script intentionally does **not** resize the Debian source image.

The final cloud image keeps the virtual size of the official Debian 11 generic cloud image. The destination cloud platform can provide a larger root disk when creating an instance, and the existing cloud guest utilities can handle first-boot partition growth where supported by the platform and image configuration.

## SSH and Cloud-init Configuration

The image contains the following SSH override:

```text
/etc/ssh/sshd_config.d/99-cloud-image.conf
```

with:

```text
PermitRootLogin yes
PasswordAuthentication yes
```

The cloud-init override is stored at:

```text
/etc/cloud/cloud.cfg.d/99-cloud-image.cfg
```

with:

```yaml
disable_root: false
ssh_pwauth: true
```

The image does **not** contain a fixed root password. Credentials should be injected by the destination cloud platform through cloud-init.

> Password-based root SSH access increases exposure. Prefer SSH keys where possible and enable password authentication only when the provisioning workflow requires it.

## QEMU Guest Agent

`qemu-guest-agent` is installed inside the generated image.

For OpenStack, configure the image to expose the QEMU guest-agent VirtIO channel:

```text
hw_qemu_guest_agent=yes
```

Example:

```bash
openstack image set \
  --property hw_qemu_guest_agent=yes \
  debian-11-cloud
```

## Example OpenStack Upload

```bash
openstack image create "Debian 11 Cloud" \
  --file debian-11-cloud.qcow2 \
  --disk-format qcow2 \
  --container-format bare \
  --property os_distro=debian \
  --property os_version=11 \
  --property hw_qemu_guest_agent=yes
```

## Integrity Verification

The script generates a SHA256 checksum automatically.

Verify the downloaded or transferred final image with:

```bash
sha256sum -c debian-11-cloud.qcow2.sha256
```

Expected result:

```text
debian-11-cloud.qcow2: OK
```

## Important Notes

### Do not commit generated images

QCOW2, IMG, RAW, ISO, and checksum artifacts generated during builds should not be committed to the repository.

The included `.gitignore` excludes these files.

### Keep the working image until validation is complete

The script keeps `debian11-working.qcow2` after the build. Keep it until the final image has been validated on the destination platform.

### Resolver handling

Debian's original `/etc/resolv.conf` is backed up before package installation. The build host's active resolver configuration is copied into the guest only temporarily, then the original Debian resolver entry is restored before finalization.

### Machine identity

`virt-sysprep` removes machine-specific data but can create a new `/etc/machine-id` during processing. The script therefore performs a second cleanup pass after sysprep and requires the final image to contain a zero-length machine-id and no SSH host keys.

## Troubleshooting

### DNS fails during package installation

Confirm the build host itself can resolve Debian repositories:

```bash
getent hosts deb.debian.org
getent hosts security.debian.org
```

The script temporarily copies the host's `/etc/resolv.conf` into the mounted image for the chroot package-installation phase.

### The QCOW2 image is locked

Check which process is using it:

```bash
lsof /opt/images/debian11/debian11-working.qcow2
```

Do not terminate unrelated QEMU processes. Make sure the guest filesystem and any bind mounts have been cleanly unmounted first.

### virt-sparsify needs more temporary disk space

Choose a temporary directory on a filesystem with more free space:

```bash
sudo -E TMPDIR_BUILD=/path/with/free/space ./build-debian11-cloud-image.sh
```

## License

Add a license file that matches how you want others to use this repository. A permissive license such as MIT is commonly used for infrastructure utility scripts.
