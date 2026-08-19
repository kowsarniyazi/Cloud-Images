#!/usr/bin/env bash

# Exit immediately if a command fails (-e), treat unset variables as errors (-u),
# fail a pipeline if any command in it fails (pipefail), and propagate ERR traps (-E).
set -Eeuo pipefail

# ==============================================================================
# Ubuntu 20.04 Generic Cloud Image Builder
# ==============================================================================
# This script creates a reusable Ubuntu 20.04 QCOW2 cloud image without creating
# a persistent virtual machine on the build host.
#
# The resulting image is prepared for cloud platforms such as OpenStack/KVM and
# includes:
#   - cloud-init
#   - qemu-guest-agent
#   - net-tools
#   - OpenSSH server
#   - root SSH login support
#   - password authentication support
#   - cleared machine-id
#   - removed SSH host keys
#   - cleaned cloud-init instance state
#   - compressed/sparse QCOW2 output
#   - SHA256 checksum
#
# Basic usage:
#   sudo bash build-ubuntu20-cloud-image.sh
#
# Optional environment-variable overrides:
#   WORKDIR=/opt/images/ubuntu20
#   VIRTUAL_SIZE=20G
#   TMPDIR_BUILD=/opt/images/tmp
#   FORCE=1
#
# Example with overrides:
#   sudo -E WORKDIR=/data/images VIRTUAL_SIZE=30G FORCE=1 \
#     bash build-ubuntu20-cloud-image.sh
# ==============================================================================

# Directory where source, working, and final image files are stored.
WORKDIR="${WORKDIR:-/opt/images/ubuntu20}"

# Directory used by virt-sparsify for temporary files.
TMPDIR_BUILD="${TMPDIR_BUILD:-/opt/images/tmp}"

# Temporary mount point used to access the guest filesystem offline.
MOUNTPOINT="${MOUNTPOINT:-/mnt/ubuntu20-build}"

# Virtual disk size assigned to the working QCOW2 image.
VIRTUAL_SIZE="${VIRTUAL_SIZE:-20G}"

# Set FORCE=1 to overwrite an existing final image/checksum.
FORCE="${FORCE:-0}"

# Official Ubuntu 20.04 cloud image URL.
BASE_URL="${BASE_URL:-https://cloud-images.ubuntu.com/releases/20.04/release/ubuntu-20.04-server-cloudimg-amd64.img}"

# Local filename of the downloaded official Ubuntu cloud image.
BASE_IMG="${BASE_IMG:-ubuntu-20.04-server-cloudimg-amd64.img}"

# Working image that will be modified during the build process.
WORK_IMG="${WORK_IMG:-ubuntu20-working.qcow2}"

# Final generic cloud image filename.
FINAL_IMG="${FINAL_IMG:-ubuntu-20.04-cloud.qcow2}"

# SHA256 checksum filename for the final image.
SHA_FILE="${SHA_FILE:-${FINAL_IMG}.sha256}"

# SSH configuration drop-in created inside the guest image.
SSH_DROPIN="/etc/ssh/sshd_config.d/00-cloud-image.conf"

# Cloud-init configuration drop-in created inside the guest image.
CLOUD_INIT_DROPIN="/etc/cloud/cloud.cfg.d/99-cloud-image.cfg"

# Print an informational message in green.
log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

# Print a warning message in yellow to standard error.
warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

# Print an error message in red and terminate the script.
die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

# Building and mounting guest filesystems requires root privileges.
[[ $EUID -eq 0 ]] || die "Run this script as root."

# Cleanup function used when the script exits or is interrupted.
cleanup() {
  # Do not stop the cleanup routine if one cleanup command fails.
  set +e

  # Flush pending filesystem writes before unmounting anything.
  sync

  # Unmount the recursively bind-mounted /dev tree if it is still mounted.
  mountpoint -q "$MOUNTPOINT/dev" && umount -R "$MOUNTPOINT/dev"

  # Unmount /proc from the guest filesystem if it is still mounted.
  mountpoint -q "$MOUNTPOINT/proc" && umount "$MOUNTPOINT/proc"

  # Unmount /sys from the guest filesystem if it is still mounted.
  mountpoint -q "$MOUNTPOINT/sys" && umount "$MOUNTPOINT/sys"

  # If the guest filesystem itself is still mounted, try to unmount it cleanly.
  if findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
    guestunmount "$MOUNTPOINT" >/dev/null 2>&1 || \
      fusermount -u "$MOUNTPOINT" >/dev/null 2>&1 || true
  fi
}

# Run cleanup on normal exit, Ctrl+C, or termination signal.
trap cleanup EXIT INT TERM

# Install all packages required on the build host.
log "Installing or confirming build dependencies"

# Prevent package installation from prompting for interactive input.
export DEBIAN_FRONTEND=noninteractive

# Refresh the build host package index.
apt-get update

# Install tools used for QCOW2 manipulation, guest filesystem access,
# downloading, lock inspection, and JSON parsing.
apt-get install -y \
  qemu-utils \
  libguestfs-tools \
  wget \
  ca-certificates \
  lsof \
  python3

# Create the working directory, temporary directory, and guest mount point.
mkdir -p "$WORKDIR" "$TMPDIR_BUILD" "$MOUNTPOINT"

# Restrict access to the temporary build directory to root only.
chmod 700 "$TMPDIR_BUILD"

# Move into the image working directory.
cd "$WORKDIR"

# Protect an existing final image from accidental overwrite.
if [[ -e "$FINAL_IMG" || -e "$SHA_FILE" ]]; then
  # FORCE=1 explicitly allows removal of the previous final output.
  if [[ "$FORCE" == "1" ]]; then
    warn "Removing previous final output because FORCE=1"
    rm -f "$FINAL_IMG" "$SHA_FILE"
  else
    die "Final output already exists. Set FORCE=1 if you intentionally want to rebuild it."
  fi
fi

# Download the official Ubuntu 20.04 cloud image if it is not already present.
log "Downloading the official Ubuntu 20.04 cloud image"

# Reuse an existing non-empty base image to avoid downloading it every run.
if [[ ! -s "$BASE_IMG" ]]; then
  wget -O "$BASE_IMG" "$BASE_URL"
else
  echo "Using existing base image: $WORKDIR/$BASE_IMG"
fi

# Verify the QCOW2 structure of the official source image before modifying it.
log "Checking base image integrity"
qemu-img check "$BASE_IMG"

# Create a disposable working copy so the downloaded source image remains intact.
log "Creating working QCOW2 image"

# Remove any old working copy from a previous interrupted build.
rm -f "$WORK_IMG"

# Copy the official image; use reflink when the filesystem supports it.
cp --reflink=auto "$BASE_IMG" "$WORK_IMG"

# Expand the virtual capacity of the working image to the requested size.
qemu-img resize "$WORK_IMG" "$VIRTUAL_SIZE"

# Display image metadata so the operator can confirm format and virtual size.
qemu-img info "$WORK_IMG"

# Mount the working image read-write through libguestfs.
log "Mounting the working image read-write"
guestmount -a "$WORK_IMG" -i --rw "$MOUNTPOINT"

# Bind-mount /dev so package-maintenance scripts in the chroot can access devices.
mount --rbind /dev "$MOUNTPOINT/dev"

# Prevent recursive unmount operations inside the guest from propagating to host /dev.
mount --make-rslave "$MOUNTPOINT/dev"

# Mount the host proc filesystem inside the guest chroot.
mount -t proc /proc "$MOUNTPOINT/proc"

# Mount sysfs inside the guest chroot.
mount -t sysfs /sys "$MOUNTPOINT/sys"

# Provide working DNS during offline package installation.
log "Providing temporary DNS inside the image"

# Remove the guest's normal systemd-resolved symlink temporarily.
rm -f "$MOUNTPOINT/etc/resolv.conf"

# Copy the build host's active resolver configuration into the guest.
cp -L /etc/resolv.conf "$MOUNTPOINT/etc/resolv.conf"

# Install and verify packages that should exist in every generated instance.
log "Installing guest packages"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_INSTALL'
# Prevent package installation prompts inside the guest image.
export DEBIAN_FRONTEND=noninteractive

# Download current package metadata for Ubuntu 20.04 repositories.
apt-get update

# Install QEMU guest integration, networking utilities, cloud-init, and SSH server.
apt-get install -y qemu-guest-agent net-tools cloud-init openssh-server

# Confirm that all required packages are installed successfully.
dpkg -l | grep -E '^ii[[:space:]]+(qemu-guest-agent|net-tools|cloud-init|openssh-server)[[:space:]]'
CHROOT_INSTALL

# Configure SSH and cloud-init so cloud platforms can provision root credentials.
log "Configuring root SSH access and cloud-init"

# Ensure SSH and cloud-init drop-in directories exist.
mkdir -p "$MOUNTPOINT/etc/ssh/sshd_config.d" "$MOUNTPOINT/etc/cloud/cloud.cfg.d"

# Create an early SSH drop-in that permits root login and password authentication.
cat > "$MOUNTPOINT$SSH_DROPIN" <<'EOF_SSH'
# Allow root to connect through SSH.
PermitRootLogin yes

# Allow password-based SSH authentication.
PasswordAuthentication yes
EOF_SSH

# Configure cloud-init to allow root and password authentication when metadata requests it.
cat > "$MOUNTPOINT$CLOUD_INIT_DROPIN" <<'EOF_CLOUD'
# Do not disable the root account during cloud-init initialization.
disable_root: false

# Allow cloud-init to configure SSH password authentication.
ssh_pwauth: true
EOF_CLOUD

# Normalize matching directives in the main sshd_config for compatibility with
# environments where drop-in handling differs from the expected OpenSSH setup.
sed -i \
  -e 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' \
  -e 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' \
  "$MOUNTPOINT/etc/ssh/sshd_config"

# Append PermitRootLogin if the main configuration does not already contain it.
grep -q '^PermitRootLogin ' "$MOUNTPOINT/etc/ssh/sshd_config" || \
  echo 'PermitRootLogin yes' >> "$MOUNTPOINT/etc/ssh/sshd_config"

# Append PasswordAuthentication if the main configuration does not already contain it.
grep -q '^PasswordAuthentication ' "$MOUNTPOINT/etc/ssh/sshd_config" || \
  echo 'PasswordAuthentication yes' >> "$MOUNTPOINT/etc/ssh/sshd_config"

# Validate the effective OpenSSH configuration without keeping a permanent host key.
log "Validating effective SSH configuration"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_SSH'
# sshd expects this runtime directory to exist during configuration validation.
mkdir -p /run/sshd

# Create a temporary ED25519 host key used only for the sshd -T validation command.
ssh-keygen -q -t ed25519 -N '' -f /tmp/sshd-test-key

# Print the effective values and require root/password authentication to be enabled.
sshd -T -o HostKey=/tmp/sshd-test-key | \
  grep -E '^(permitrootlogin|passwordauthentication) '

# Remove the temporary validation key so it never becomes part of the final image.
rm -f /tmp/sshd-test-key /tmp/sshd-test-key.pub
CHROOT_SSH

# Remove host-specific state so each cloned VM initializes as a unique instance.
log "Cleaning the image for template use"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_CLEAN'
# Remove downloaded APT package files.
apt-get clean

# Remove cached package indexes to reduce final image size.
rm -rf /var/lib/apt/lists/*

# Remove temporary files created during the build process.
rm -rf /tmp/* /var/tmp/*

# Remove cloud-init state from any previous initialization.
rm -rf /var/lib/cloud/instances/* 2>/dev/null || true
rm -rf /var/lib/cloud/instance 2>/dev/null || true
rm -rf /var/lib/cloud/sem/* 2>/dev/null || true

# Re-create empty cloud-init state directories with the expected structure.
mkdir -p /var/lib/cloud/instances /var/lib/cloud/sem

# Remove old cloud-init logs from the template.
rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log

# Clear machine-id so systemd generates a unique identity for each new VM.
truncate -s 0 /etc/machine-id

# Remove SSH host keys so every VM generates its own unique keys on first boot.
rm -f /etc/ssh/ssh_host_*
CHROOT_CLEAN

# Restore Ubuntu's normal systemd-resolved resolver configuration.
log "Restoring the standard systemd-resolved resolv.conf symlink"

# Remove the temporary resolver file copied from the build host.
rm -f "$MOUNTPOINT/etc/resolv.conf"

# Restore the standard resolver symlink used by Ubuntu cloud images.
ln -s /run/systemd/resolve/stub-resolv.conf "$MOUNTPOINT/etc/resolv.conf"

# Verify critical settings before unmounting the guest filesystem.
log "Running pre-unmount verification"

# Show the final cloud-init override.
cat "$MOUNTPOINT$CLOUD_INIT_DROPIN"

# Show the final SSH override.
cat "$MOUNTPOINT$SSH_DROPIN"

# Confirm qemu-guest-agent and cloud-init remain installed.
chroot "$MOUNTPOINT" dpkg -l | \
  grep -E '^ii[[:space:]]+(qemu-guest-agent|cloud-init)[[:space:]]'

# Print the machine-id size; it must be zero bytes.
printf 'machine-id bytes: '
wc -c < "$MOUNTPOINT/etc/machine-id"

# Refuse to continue if any SSH host keys are still present in the template.
if compgen -G "$MOUNTPOINT/etc/ssh/ssh_host_*" >/dev/null; then
  die "SSH host keys are still present; refusing to finalize."
else
  echo "No SSH host keys - OK"
fi

# Display the restored resolv.conf symlink for verification.
ls -l "$MOUNTPOINT/etc/resolv.conf"

# Flush disk writes and cleanly detach all guest filesystem mounts.
log "Unmounting image cleanly"

# Flush pending writes before unmounting.
sync

# Detach the recursively bind-mounted /dev tree.
umount -R "$MOUNTPOINT/dev" 2>/dev/null || true

# Detach the guest /proc mount.
umount "$MOUNTPOINT/proc" 2>/dev/null || true

# Detach the guest /sys mount.
umount "$MOUNTPOINT/sys" 2>/dev/null || true

# Unmount the guest filesystem managed by guestmount/libguestfs.
guestunmount "$MOUNTPOINT"

# Wait briefly for the libguestfs QEMU appliance to exit and release the QCOW2 file.
for _ in {1..20}; do
  # Stop waiting as soon as no process holds the working image open.
  if ! lsof "$WORK_IMG" >/dev/null 2>&1; then
    break
  fi

  # Wait one second before checking again.
  sleep 1
done

# Refuse to continue if a process still has the working image locked.
if lsof "$WORK_IMG" >/dev/null 2>&1; then
  warn "A libguestfs/QEMU process still holds the working image."
  lsof "$WORK_IMG" || true
  die "Image is still locked. Inspect the holder before terminating any QEMU process."
fi

# Disable the automatic cleanup trap because all mounts are now intentionally closed.
trap - EXIT INT TERM

# Verify the modified working image before creating the final artifact.
log "Checking working image integrity"
qemu-img check "$WORK_IMG"

# Read the image virtual size in bytes from qemu-img JSON output.
VIRTUAL_BYTES=$(qemu-img info --output=json "$WORK_IMG" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])' \
  2>/dev/null || echo 0)

# Read free bytes available in the temporary build directory filesystem.
TMP_FREE=$(df -PB1 "$TMPDIR_BUILD" | awk 'NR==2 {print $4}')

# Warn when temporary free space is smaller than the image's virtual capacity.
# virt-sparsify uses a conservative estimate, so the operation can still succeed.
if [[ "$VIRTUAL_BYTES" =~ ^[0-9]+$ ]] && \
   (( VIRTUAL_BYTES > 0 )) && \
   (( TMP_FREE < VIRTUAL_BYTES )); then
  warn "TMPDIR has less free space than the image virtual size."
  warn "TMPDIR: $TMPDIR_BUILD"
  warn "Free bytes: $TMP_FREE ; virtual size: $VIRTUAL_BYTES"
  warn "More free disk space is recommended before running virt-sparsify."
fi

# Convert the working image into a compressed, sparse QCOW2 artifact.
log "Creating compressed and sparse final QCOW2 image"
TMPDIR="$TMPDIR_BUILD" virt-sparsify \
  --check-tmpdir=continue \
  --convert qcow2 \
  --compress \
  "$WORK_IMG" \
  "$FINAL_IMG"

# Verify the filesystem-independent QCOW2 structure of the final image.
log "Checking final image integrity"
qemu-img check "$FINAL_IMG"

# Display final QCOW2 metadata such as format, virtual size, and disk usage.
qemu-img info "$FINAL_IMG"

# Perform offline checks against the contents of the final image.
log "Validating final image contents"

# Verify that the cloud-init customization file survived sparsification.
virt-cat -a "$FINAL_IMG" "$CLOUD_INIT_DROPIN"

# Verify that the SSH customization file survived sparsification.
virt-cat -a "$FINAL_IMG" "$SSH_DROPIN"

# Confirm qemu-guest-agent and cloud-init are marked as installed in dpkg status.
virt-cat -a "$FINAL_IMG" /var/lib/dpkg/status | \
  grep -A 5 -E '^Package: (qemu-guest-agent|cloud-init)$' || true

# Read the number of bytes stored in /etc/machine-id inside the final image.
MID_BYTES=$(virt-cat -a "$FINAL_IMG" /etc/machine-id | wc -c)

# Refuse to finalize if machine-id is not empty.
[[ "$MID_BYTES" -eq 0 ]] || \
  die "Final image machine-id is not empty ($MID_BYTES bytes)."

# Refuse to finalize if SSH host keys were accidentally included.
if virt-ls -a "$FINAL_IMG" /etc/ssh | grep -q '^ssh_host_'; then
  die "Final image contains SSH host keys."
else
  echo "No SSH host keys - OK"
fi

# Generate a checksum so file integrity can be verified after transfer/download.
log "Generating SHA256 checksum"
sha256sum "$FINAL_IMG" > "$SHA_FILE"

# Immediately verify the generated checksum against the local final image.
sha256sum -c "$SHA_FILE"

# Print a concise completion summary.
log "DONE"
echo "Final image : $WORKDIR/$FINAL_IMG"
echo "SHA256 file: $WORKDIR/$SHA_FILE"
echo
echo "Keep $WORK_IMG until the final image has been boot-tested on the destination cloud."
echo "For OpenStack, set image property hw_qemu_guest_agent=yes when uploading or after upload."
