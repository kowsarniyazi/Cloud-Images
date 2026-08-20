#!/usr/bin/env bash

# Exit immediately on errors, fail on unset variables, and propagate pipeline failures.
set -Eeuo pipefail

# ==============================================================================
# Debian 11 Generic Cloud Image Builder
# ==============================================================================
# This script builds a reusable Debian 11 (Bullseye) QCOW2 cloud image from the
# official Debian generic cloud image without creating a persistent VM.
#
# The resulting image is prepared for KVM/OpenStack environments and includes:
#   - cloud-init
#   - cloud-guest-utils
#   - qemu-guest-agent
#   - OpenSSH server
#   - root SSH login support
#   - password authentication support
#   - cleared machine-id
#   - removed SSH host keys
#   - cleaned cloud-init instance state
#   - compressed/sparse QCOW2 output
#   - SHA256 checksum
#
# The source image keeps its original virtual size. This script does not resize
# the virtual disk.
#
# Basic usage:
#   sudo bash build-debian11-cloud-image.sh
#
# Optional environment-variable overrides:
#   WORKDIR=/opt/images/debian11
#   TMPDIR_BUILD=/opt/images/tmp
#   MOUNTPOINT=/mnt/debian11-build
#   FORCE=1
#
# Example:
#   sudo -E WORKDIR=/data/images/debian11 TMPDIR_BUILD=/data/tmp FORCE=1 \
#     bash build-debian11-cloud-image.sh
# ==============================================================================

# Directory where source, working, and final image files are stored.
WORKDIR="${WORKDIR:-/opt/images/debian11}"

# Directory used by virt-sparsify for temporary files.
TMPDIR_BUILD="${TMPDIR_BUILD:-/opt/images/tmp}"

# Temporary mount point used to access the guest filesystem offline.
MOUNTPOINT="${MOUNTPOINT:-/mnt/debian11-build}"

# Set FORCE=1 to overwrite an existing final image/checksum.
FORCE="${FORCE:-0}"

# Official Debian 11 generic cloud image and checksum URLs.
BASE_URL="${BASE_URL:-https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2}"
SUMS_URL="${SUMS_URL:-https://cloud.debian.org/images/cloud/bullseye/latest/SHA512SUMS}"

# Local filenames used during the build.
BASE_IMG="${BASE_IMG:-debian-11-generic-amd64.qcow2}"
SUMS_FILE="${SUMS_FILE:-SHA512SUMS}"
WORK_IMG="${WORK_IMG:-debian11-working.qcow2}"
FINAL_IMG="${FINAL_IMG:-debian-11-cloud.qcow2}"
SHA_FILE="${SHA_FILE:-${FINAL_IMG}.sha256}"

# Generic guest configuration drop-ins.
SSH_DROPIN="/etc/ssh/sshd_config.d/99-cloud-image.conf"
CLOUD_INIT_DROPIN="/etc/cloud/cloud.cfg.d/99-cloud-image.cfg"
RESOLV_BACKUP="/etc/resolv.conf.before-cloud-image-build"

# Print an informational message.
log() {
  printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
}

# Print a warning message to standard error.
warn() {
  printf '\n\033[1;33m[!] %s\033[0m\n' "$*" >&2
}

# Print an error message and terminate the script.
die() {
  printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
  exit 1
}

# Building and mounting guest filesystems requires root privileges.
[[ $EUID -eq 0 ]] || die "Run this script as root."

# Clean up mounts when the script exits or is interrupted.
cleanup() {
  set +e
  sync

  # Unmount the recursively bind-mounted /dev tree first.
  mountpoint -q "$MOUNTPOINT/dev" && umount -R "$MOUNTPOINT/dev"

  # Unmount guest proc and sysfs mounts.
  mountpoint -q "$MOUNTPOINT/proc" && umount "$MOUNTPOINT/proc"
  mountpoint -q "$MOUNTPOINT/sys" && umount "$MOUNTPOINT/sys"

  # Unmount the guest filesystem managed by libguestfs/FUSE.
  if findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
    guestunmount "$MOUNTPOINT" >/dev/null 2>&1 || \
      fusermount -u "$MOUNTPOINT" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

# Install or confirm build-host dependencies.
log "Installing or confirming build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  qemu-utils \
  libguestfs-tools \
  wget \
  ca-certificates \
  lsof \
  python3

# Prepare build directories.
mkdir -p "$WORKDIR" "$TMPDIR_BUILD" "$MOUNTPOINT"
chmod 700 "$TMPDIR_BUILD"
cd "$WORKDIR"

# Protect an existing final artifact from accidental overwrite.
if [[ -e "$FINAL_IMG" || -e "$SHA_FILE" ]]; then
  if [[ "$FORCE" == "1" ]]; then
    warn "Removing previous final output because FORCE=1"
    rm -f "$FINAL_IMG" "$SHA_FILE"
  else
    die "Final output already exists. Set FORCE=1 to rebuild intentionally."
  fi
fi

# Download the official Debian 11 image and its SHA512 checksum list.
log "Downloading the official Debian 11 generic cloud image"
if [[ ! -s "$BASE_IMG" ]]; then
  wget -O "$BASE_IMG" "$BASE_URL"
else
  echo "Using existing base image: $WORKDIR/$BASE_IMG"
fi

log "Downloading Debian SHA512 checksums"
wget -O "$SUMS_FILE" "$SUMS_URL"

# Verify the downloaded source image against Debian's published SHA512 checksum.
log "Verifying source image SHA512 checksum"
SUM_LINE=$(grep "${BASE_IMG}$" "$SUMS_FILE" || true)
[[ -n "$SUM_LINE" ]] || die "No checksum entry found for $BASE_IMG in $SUMS_FILE."
printf '%s\n' "$SUM_LINE" | sha512sum -c -

# Verify the QCOW2 structure before modifying anything.
log "Checking base image integrity"
qemu-img check "$BASE_IMG"
qemu-img info "$BASE_IMG"

# Create a disposable working copy while keeping the official source untouched.
log "Creating working QCOW2 copy"
rm -f "$WORK_IMG"
cp --reflink=auto "$BASE_IMG" "$WORK_IMG"
qemu-img check "$WORK_IMG"
qemu-img info "$WORK_IMG"

# Mount the working image read-write through libguestfs.
log "Mounting working image"
guestmount -a "$WORK_IMG" -i --rw "$MOUNTPOINT"

# Preserve Debian's original resolver configuration exactly as it exists.
[[ -e "$MOUNTPOINT/etc/resolv.conf" || -L "$MOUNTPOINT/etc/resolv.conf" ]] || \
  die "Guest /etc/resolv.conf does not exist."
cp -a "$MOUNTPOINT/etc/resolv.conf" "$MOUNTPOINT$RESOLV_BACKUP"

# Temporarily use the build host's resolver so APT works inside the chroot.
rm -f "$MOUNTPOINT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MOUNTPOINT/etc/resolv.conf"

# Bind host kernel interfaces required by package-maintenance scripts in chroot.
mount --rbind /dev "$MOUNTPOINT/dev"
mount --make-rslave "$MOUNTPOINT/dev"
mount -t proc proc "$MOUNTPOINT/proc"
mount -t sysfs sysfs "$MOUNTPOINT/sys"

# Update package metadata, install QEMU guest integration, and confirm required packages.
log "Installing qemu-guest-agent and verifying cloud packages"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_INSTALL'
export DEBIAN_FRONTEND=noninteractive

# Use root for APT downloads because guestmount/FUSE can prevent the _apt user
# from accessing APT's partial-download directory inside the chroot.
apt-get -o APT::Sandbox::User=root update
apt-get -o APT::Sandbox::User=root install -y qemu-guest-agent

# The official Debian generic cloud image is expected to provide these packages.
dpkg -l | grep -E '^ii[[:space:]]+(cloud-init|cloud-guest-utils|openssh-server|qemu-guest-agent)[[:space:]]'
CHROOT_INSTALL

# Create generic SSH and cloud-init configuration overrides.
log "Configuring SSH and cloud-init"
mkdir -p "$MOUNTPOINT/etc/ssh/sshd_config.d" "$MOUNTPOINT/etc/cloud/cloud.cfg.d"

cat > "$MOUNTPOINT$SSH_DROPIN" <<'EOF_SSH'
# Allow root to connect through SSH.
PermitRootLogin yes

# Allow password-based SSH authentication.
PasswordAuthentication yes
EOF_SSH

cat > "$MOUNTPOINT$CLOUD_INIT_DROPIN" <<'EOF_CLOUD'
# Keep the root account available for cloud provisioning.
disable_root: false

# Allow cloud-init to configure SSH password authentication.
ssh_pwauth: true
EOF_CLOUD

# Validate the effective OpenSSH configuration with a temporary host key.
log "Validating effective SSH configuration"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_SSH'
mkdir -p /run/sshd
ssh-keygen -q -t ed25519 -N '' -f /tmp/cloud-image-sshd-test-key
sshd -T -h /tmp/cloud-image-sshd-test-key | \
  grep -E '^(permitrootlogin|passwordauthentication) '
rm -f /tmp/cloud-image-sshd-test-key /tmp/cloud-image-sshd-test-key.pub
CHROOT_SSH

# Restore Debian's original resolver configuration before finalizing the image.
log "Restoring original Debian resolver configuration"
rm -f "$MOUNTPOINT/etc/resolv.conf"
mv "$MOUNTPOINT$RESOLV_BACKUP" "$MOUNTPOINT/etc/resolv.conf"
ls -l "$MOUNTPOINT/etc/resolv.conf"

# Perform the first cleanup pass before virt-sysprep.
log "Cleaning package and cloud-init state"
chroot "$MOUNTPOINT" /bin/bash -euxo pipefail <<'CHROOT_CLEAN'
apt-get clean
rm -rf /var/lib/apt/lists/*
cloud-init clean --logs || true
rm -rf /tmp/* /var/tmp/*
CHROOT_CLEAN

# Flush writes and unmount the working image cleanly.
log "Unmounting image before virt-sysprep"
sync
umount -R "$MOUNTPOINT/dev" 2>/dev/null || true
umount "$MOUNTPOINT/proc" 2>/dev/null || true
umount "$MOUNTPOINT/sys" 2>/dev/null || true
guestunmount "$MOUNTPOINT"

# Wait for libguestfs to release the working image lock.
for _ in {1..20}; do
  if ! lsof "$WORK_IMG" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if lsof "$WORK_IMG" >/dev/null 2>&1; then
  warn "A process still holds the working image open."
  lsof "$WORK_IMG" || true
  die "Working image is still locked."
fi

# Verify the image before sysprep.
log "Checking working image before virt-sysprep"
qemu-img check "$WORK_IMG"

# Remove machine-specific state using libguestfs.
log "Running virt-sysprep"
virt-sysprep -a "$WORK_IMG"

# Verify the image immediately after sysprep.
qemu-img check "$WORK_IMG"

# virt-sysprep can create a new machine-id, so perform a final cleanup pass after it.
log "Performing final template cleanup"
guestmount -a "$WORK_IMG" -i --rw "$MOUNTPOINT"

# Confirm the custom configuration survived sysprep.
cat "$MOUNTPOINT$SSH_DROPIN"
cat "$MOUNTPOINT$CLOUD_INIT_DROPIN"

# Remove cloud-init instance state and logs so first-boot initialization runs again.
rm -rf "$MOUNTPOINT/var/lib/cloud/instances/"*
rm -rf "$MOUNTPOINT/var/lib/cloud/instance" 2>/dev/null || true
rm -rf "$MOUNTPOINT/var/lib/cloud/sem/"* 2>/dev/null || true
mkdir -p "$MOUNTPOINT/var/lib/cloud/instances" "$MOUNTPOINT/var/lib/cloud/sem"
rm -f "$MOUNTPOINT/var/log/cloud-init.log" "$MOUNTPOINT/var/log/cloud-init-output.log"

# Clear machine-id so every new VM receives a unique system identity.
truncate -s 0 "$MOUNTPOINT/etc/machine-id"

# Keep the traditional D-Bus machine-id path linked to the system machine-id.
rm -f "$MOUNTPOINT/var/lib/dbus/machine-id"
ln -s /etc/machine-id "$MOUNTPOINT/var/lib/dbus/machine-id"

# Remove SSH host keys so every VM generates unique keys on first boot.
rm -f "$MOUNTPOINT/etc/ssh/ssh_host_"*

# Remove temporary files created during the build.
rm -rf "$MOUNTPOINT/tmp/"* "$MOUNTPOINT/var/tmp/"* 2>/dev/null || true

# Verify qemu-guest-agent is still installed.
grep -A 3 '^Package: qemu-guest-agent$' "$MOUNTPOINT/var/lib/dpkg/status" | \
  grep -q '^Status: install ok installed$' || die "qemu-guest-agent is not installed in the final working image."

# Verify machine-id is empty.
MID_BYTES=$(wc -c < "$MOUNTPOINT/etc/machine-id")
[[ "$MID_BYTES" -eq 0 ]] || die "machine-id is not empty."

# Refuse to continue if SSH host keys remain.
if compgen -G "$MOUNTPOINT/etc/ssh/ssh_host_*" >/dev/null; then
  die "SSH host keys are still present; refusing to finalize."
else
  echo "No SSH host keys - OK"
fi

# Display the restored Debian resolver path for verification.
ls -l "$MOUNTPOINT/etc/resolv.conf"

# Flush pending writes and unmount the final working filesystem.
sync
guestunmount "$MOUNTPOINT"

# Wait for libguestfs to release the image before qemu-img/virt-sparsify runs.
for _ in {1..20}; do
  if ! lsof "$WORK_IMG" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if lsof "$WORK_IMG" >/dev/null 2>&1; then
  warn "A process still holds the working image open after final cleanup."
  lsof "$WORK_IMG" || true
  die "Working image is still locked."
fi

# Automatic cleanup is no longer needed because all mounts are closed intentionally.
trap - EXIT INT TERM

# Verify the final working image before producing the artifact.
log "Checking working image integrity"
qemu-img check "$WORK_IMG"

# Warn if the selected temporary filesystem has less free space than the virtual disk.
VIRTUAL_BYTES=$(qemu-img info --output=json "$WORK_IMG" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])' \
  2>/dev/null || echo 0)
TMP_FREE=$(df -PB1 "$TMPDIR_BUILD" | awk 'NR==2 {print $4}')

if [[ "$VIRTUAL_BYTES" =~ ^[0-9]+$ ]] && \
   (( VIRTUAL_BYTES > 0 )) && \
   (( TMP_FREE < VIRTUAL_BYTES )); then
  warn "TMPDIR has less free space than the image virtual size."
  warn "TMPDIR: $TMPDIR_BUILD"
  warn "Free bytes: $TMP_FREE ; virtual size: $VIRTUAL_BYTES"
fi

# Create the final compressed and sparse QCOW2 image without resizing it.
log "Creating final compressed QCOW2 image"
TMPDIR="$TMPDIR_BUILD" virt-sparsify \
  --check-tmpdir=continue \
  --convert qcow2 \
  --compress \
  "$WORK_IMG" \
  "$FINAL_IMG"

# Verify final QCOW2 integrity and display metadata.
log "Checking final image integrity"
qemu-img check "$FINAL_IMG"
qemu-img info "$FINAL_IMG"

# Validate critical content inside the final artifact.
log "Validating final image contents"
virt-cat -a "$FINAL_IMG" -i "$CLOUD_INIT_DROPIN"
virt-cat -a "$FINAL_IMG" -i "$SSH_DROPIN"

virt-cat -a "$FINAL_IMG" -i /var/lib/dpkg/status | \
  grep -A 5 -E '^Package: (qemu-guest-agent|cloud-init)$' || true

MID_BYTES=$(virt-cat -a "$FINAL_IMG" -i /etc/machine-id | wc -c)
[[ "$MID_BYTES" -eq 0 ]] || \
  die "Final image machine-id is not empty ($MID_BYTES bytes)."

if virt-ls -a "$FINAL_IMG" -i /etc/ssh | grep -q '^ssh_host_'; then
  die "Final image contains SSH host keys."
else
  echo "No SSH host keys - OK"
fi

# Generate and immediately verify the SHA256 checksum.
log "Generating SHA256 checksum"
sha256sum "$FINAL_IMG" > "$SHA_FILE"
sha256sum -c "$SHA_FILE"

# Print a concise completion summary.
log "DONE"
echo "Final image : $WORKDIR/$FINAL_IMG"
echo "SHA256 file: $WORKDIR/$SHA_FILE"
echo
echo "The source image keeps its original virtual size; no resize operation was performed."
echo "For OpenStack, set image property hw_qemu_guest_agent=yes."
