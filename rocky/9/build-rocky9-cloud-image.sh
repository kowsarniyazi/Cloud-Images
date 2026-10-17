#!/usr/bin/env bash
# Build a reusable Rocky Linux 9 QCOW2 cloud image for KVM/OpenStack.
# Root password is not embedded. Supply a unique password at provisioning time.
set -Eeuo pipefail

IMAGE_URL="${IMAGE_URL:-https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2}"
WORK_DIR="${WORK_DIR:-$PWD/build}"
OUTPUT_NAME="${OUTPUT_NAME:-rocky-9-cloud.qcow2}"
SOURCE_NAME="rocky9-original.qcow2"
WORK_NAME="rocky9-working.qcow2"

fail() { echo "ERROR: $*" >&2; exit 1; }
for command in curl sha256sum awk qemu-img virt-customize virt-sysprep virt-sparsify virt-cat virt-inspector; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing dependency: $command"
done
[[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
[[ "$OUTPUT_NAME" != */* ]] || fail "OUTPUT_NAME must be a filename."
source_file="$WORK_DIR/$SOURCE_NAME"
working_file="$WORK_DIR/$WORK_NAME"
output_file="$WORK_DIR/$OUTPUT_NAME"
checksum_file="$WORK_DIR/rocky9-original.CHECKSUM"
[[ ! -e "$working_file" && ! -e "$output_file" ]] || fail "Working/output file already exists; refusing to overwrite it."
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

# Download a fresh checksum and the source image, or verify an existing source.
echo '[1/7] Downloading official Rocky Linux image and checksum'
curl --fail --location --retry 3 --silent --show-error \
  "${IMAGE_URL}.CHECKSUM" -o "$checksum_file"
if [[ ! -f "$source_file" ]]; then
  curl --fail --location --retry 3 --continue-at - \
    "$IMAGE_URL" -o "$source_file"
fi
expected="$(awk '/^SHA256 \(/ {print $NF; exit}' "$checksum_file")"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Could not parse a SHA256 checksum from the official checksum file.'
echo "$expected  $source_file" | sha256sum --check --status || fail 'SHA256 mismatch: source image is not trustworthy.'
qemu-img check "$source_file" || fail 'Source QCOW2 verification failed.'

# Copy the verified source to protect the original image.
echo '[2/7] Creating working copy'
cp --reflink=auto -- "$source_file" "$working_file"

# Confirm package presence before editing. Official GenericCloud images normally include them.
echo '[3/7] Checking preinstalled cloud packages'
inspection="$(virt-inspector -a "$working_file")"
for pkg in cloud-init qemu-guest-agent cloud-utils-growpart openssh-server; do
  printf '%s' "$inspection" | grep -Eq "<name>${pkg}</name>" || fail "Package not detected: $pkg. Install it in a reviewed separate build stage."
done

# Keep the existing Rocky base config; only add small cloud-specific overrides.
cat > "$tmp_dir/99-cloud.cfg" <<'EOF'
#cloud-config
ssh_pwauth: true
disable_root: false
preserve_hostname: false
system_info:
  default_user:
    name: root
    lock_passwd: false
    shell: /bin/bash
EOF
cat > "$tmp_dir/01-root-login.conf" <<'EOF'
# Allow password and key authentication for root in this cloud image.
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

echo '[4/7] Applying cloud-init and SSH configuration'
virt-customize -a "$working_file" \
  --upload "$tmp_dir/99-cloud.cfg:/etc/cloud/cloud.cfg.d/99-cloud.cfg" \
  --upload "$tmp_dir/01-root-login.conf:/etc/ssh/sshd_config.d/01-root-login.conf"

# Remove instance-specific IDs and credentials; do not run the guest VM here.
echo '[5/7] Removing machine-specific state'
virt-sysprep -a "$working_file" \
  --operations machine-id,ssh-hostkeys,logfiles,dhcp-client-state,bash-history

# Preserve the original virtual disk size, compressing only allocated data.
echo '[6/7] Creating compressed QCOW2 output'
virt-sparsify --compress "$working_file" "$output_file"

echo '[7/7] Verifying final image'
qemu-img check "$output_file"
virt-cat -a "$output_file" /etc/cloud/cloud.cfg.d/99-cloud.cfg >/dev/null
virt-cat -a "$output_file" /etc/ssh/sshd_config.d/01-root-login.conf >/dev/null
(cd "$WORK_DIR" && sha256sum "$OUTPUT_NAME" > "${OUTPUT_NAME}.sha256")
qemu-img info "$output_file"
echo "Created: $output_file"
echo "SHA256: ${output_file}.sha256"
echo 'IMPORTANT: Test boot, root password injection, SSH, network, disk growth, and guest agent before production use.'
