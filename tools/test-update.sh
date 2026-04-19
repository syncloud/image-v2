#!/bin/sh -ex

# End-to-end RAUC A/B update test for amd64 UEFI image.
#
# Flow:
#   1. Generate test-only signing keys, inject cert into both slots'
#      /etc/rauc/keyring.pem so the image trusts our test bundles.
#   2. Build two bundles (v2, v3) from the image's rootfs-a, each with
#      a distinct /etc/syncloud-test-version sentinel.
#   3. Serve bundles + manifest.json on :8000 (QEMU SLIRP gateway is
#      10.0.2.2 from the guest's perspective — no hostfwd needed).
#   4. Boot image in QEMU, SSH in, point UPDATE_URL at the mock server,
#      trigger update, wait for reboot, verify slot flipped and
#      sentinel matches.
#   5. Serve bundle v3, trigger again, verify slot flipped back.
#
# Usage: ./tools/test-update.sh <image.img.xz>

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    qemu-system-x86 ovmf sshpass openssh-client xz-utils \
    python3 rauc squashfs-tools e2fsprogs openssl kpartx

IMAGE_XZ=$1
if [ -z "$IMAGE_XZ" ] || [ ! -f "$IMAGE_XZ" ]; then
    echo "Usage: $0 <image.img.xz>"
    exit 1
fi

WORK_DIR=$(mktemp -d)
IMAGE="$WORK_DIR/test.img"
SSH_PORT=2222
SSH="sshpass -p syncloud ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p $SSH_PORT root@localhost"

QEMU_PID=""
HTTPD_PID=""
cleanup() {
    set +e
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
    [ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "=== Decompressing image ($(date)) ==="
xz -dk "$IMAGE_XZ" -c > "$IMAGE"
ls -lh "$IMAGE"

# --- Generate test signing keys and inject cert into both slots ---
echo "=== Generating test keys + injecting cert ($(date)) ==="
KEY_DIR="$WORK_DIR/keys"
mkdir -p "$KEY_DIR"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_DIR/key.pem" -out "$KEY_DIR/cert.pem" \
    -days 1 -subj "/CN=rauc-test" >/dev/null 2>&1

LOOP=$(losetup --find --show "$IMAGE")
LOOP_NAME=$(basename "$LOOP")
kpartx -avs "$LOOP"
ROOTFS_A="/dev/mapper/${LOOP_NAME}p2"
ROOTFS_B="/dev/mapper/${LOOP_NAME}p3"
MNT="$WORK_DIR/mnt"
mkdir -p "$MNT"
for dev in "$ROOTFS_A" "$ROOTFS_B"; do
    mount "$dev" "$MNT"
    cp "$KEY_DIR/cert.pem" "$MNT/etc/rauc/keyring.pem"
    umount "$MNT"
done

# --- Snapshot rootfs-a contents as bundle source ---
echo "=== Snapshotting rootfs-a for bundle source ($(date)) ==="
BUNDLE_SRC="$WORK_DIR/bundle-src.ext4"
dd if="$ROOTFS_A" of="$BUNDLE_SRC" bs=4M status=none
kpartx -d "$LOOP"
losetup -d "$LOOP"

# --- Helper: make_bundle <version> ---
make_bundle() {
    version=$1
    work="$WORK_DIR/bundle-v$version"
    mkdir -p "$work"
    cp "$BUNDLE_SRC" "$work/rootfs.img"
    m="$WORK_DIR/bundle-mnt"
    mkdir -p "$m"
    mount -o loop "$work/rootfs.img" "$m"
    echo "version=$version" > "$m/etc/syncloud-test-version"
    umount "$m"
    cat > "$work/manifest.raucm" <<EOF
[update]
compatible=syncloud-amd64-uefi
version=$version

[image.rootfs]
filename=rootfs.img
EOF
    rauc bundle \
        --cert="$KEY_DIR/cert.pem" \
        --key="$KEY_DIR/key.pem" \
        "$work" \
        "$WORK_DIR/bundle-v$version.raucb"
}

echo "=== Building bundles v2, v3 ($(date)) ==="
make_bundle 2
make_bundle 3
ls -lh "$WORK_DIR"/bundle-v*.raucb

# --- Start mock update server on :8000 (host-side) ---
# update-agent fetches from $UPDATE_URL/$COMPATIBLE/latest.json — we serve
# under a /syncloud-amd64-uefi/ path to match.
WWW="$WORK_DIR/www"
COMPATIBLE_DIR="$WWW/syncloud-amd64-uefi"
mkdir -p "$COMPATIBLE_DIR"
publish_manifest() {
    v=$1
    cp "$WORK_DIR/bundle-v$v.raucb" "$COMPATIBLE_DIR/bundle-v$v.raucb"
    cat > "$COMPATIBLE_DIR/latest.json" <<EOF
{"version": "$v", "url": "http://10.0.2.2:8000/syncloud-amd64-uefi/bundle-v$v.raucb"}
EOF
}

echo "=== Starting mock update server ($(date)) ==="
(cd "$WWW" && python3 -m http.server 8000) >"$WORK_DIR/http.log" 2>&1 &
HTTPD_PID=$!
sleep 1

# --- OVMF ---
OVMF=""
for f in /usr/share/OVMF/OVMF.fd /usr/share/ovmf/OVMF.fd; do
    [ -f "$f" ] && OVMF="$f" && break
done
[ -n "$OVMF" ] || { echo "ERROR: OVMF firmware not found"; exit 1; }
[ -e /dev/kvm ] || { echo "ERROR: /dev/kvm not available"; exit 1; }

# --- Helper: boot + wait for SSH ---
QEMU_LOG="$WORK_DIR/qemu-console.log"
boot_and_wait_ssh() {
    qemu-system-x86_64 \
        -enable-kvm \
        -bios "$OVMF" \
        -drive file="$IMAGE",format=raw,if=virtio \
        -m 1024 -smp 2 \
        -nographic -serial "file:$QEMU_LOG" \
        -net nic,model=virtio \
        -net user,hostfwd=tcp::${SSH_PORT}-:22 \
        -no-reboot >/dev/null 2>&1 &
    QEMU_PID=$!
    i=0
    while [ $i -lt 60 ]; do
        i=$((i+1))
        if $SSH echo "ssh-ok" >/dev/null 2>&1; then
            echo "SSH ready after $i attempts"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: SSH not available after 5 minutes"
    tail -40 "$QEMU_LOG"
    return 1
}

kill_qemu() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
}

# --- Helper: trigger update, wait for reboot, reboot back up ---
apply_update_and_wait() {
    expected_version=$1
    # Point guest at our mock server. Quote the remote command so the
    # '>' redirect runs on the guest, not the host.
    $SSH "sh -c 'echo UPDATE_URL=http://10.0.2.2:8000 > /etc/default/syncloud-update'"
    # Sanity check: verify the override actually landed on the guest.
    got_url=$($SSH 'cat /etc/default/syncloud-update')
    [ "$got_url" = "UPDATE_URL=http://10.0.2.2:8000" ] || {
        echo "ERROR: UPDATE_URL override didn't land on guest. got: $got_url"
        return 1
    }
    # Probe guest -> mock server reachability before triggering the update.
    # If SLIRP gateway isn't wired, the agent would silently exit 0 with
    # 'No update available' and the whole test would stall.
    echo "Probing guest connectivity to mock update server..."
    if ! $SSH "curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' http://10.0.2.2:8000/syncloud-amd64-uefi/latest.json"; then
        echo "ERROR: guest cannot reach mock server at 10.0.2.2:8000"
        echo "=== python http.server log ==="
        cat "$WORK_DIR/http.log" || true
        echo "=== host-side netstat ==="
        ss -tlnp 2>/dev/null | grep :8000 || true
        return 1
    fi
    # Trigger synchronously — script does `systemctl reboot` at the end,
    # which will tear down SSH. That's fine.
    $SSH 'systemctl start syncloud-update.service' || true
    # Wait for the VM to actually reboot: QEMU exits on reboot because
    # of -no-reboot. Time-box it so a silent no-op update doesn't hang.
    echo "Waiting for QEMU to exit (reboot)..."
    for _ in $(seq 1 120); do
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU still alive 2min after update trigger (reboot never happened)"
        echo "=== journalctl on guest ==="
        $SSH 'journalctl -u syncloud-update.service --no-pager -n 80' || true
        echo "=== rauc status on guest ==="
        $SSH 'rauc status --detailed 2>&1 || true' || true
        echo "=== python http.server log ==="
        cat "$WORK_DIR/http.log" || true
        return 1
    fi
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
    echo "Rebooting VM..."
    boot_and_wait_ssh
    # Verify sentinel
    got=$($SSH 'cat /etc/syncloud-test-version 2>/dev/null || echo MISSING')
    if [ "$got" != "version=$expected_version" ]; then
        echo "ERROR: expected sentinel version=$expected_version, got '$got'"
        return 1
    fi
    echo "Sentinel OK: $got"
}

read_slot() {
    # Kernel cmdline has rauc.slot=A or rauc.slot=B (set by grub.cfg / boot.scr)
    # — no rauc daemon / D-Bus needed.
    $SSH "grep -oE 'rauc\\.slot=[AB]' /proc/cmdline | cut -d= -f2"
}

# --- Test run ---
echo "=== Booting initial image (slot A) ($(date)) ==="
boot_and_wait_ssh
initial=$(read_slot)
echo "Initial slot: $initial"
[ "$initial" = "A" ] || { echo "ERROR: expected slot A on first boot, got '$initial'"; exit 1; }

echo "=== Cycle 1: install bundle v2, expect flip to B ($(date)) ==="
publish_manifest 2
apply_update_and_wait 2
after1=$(read_slot)
echo "After cycle 1: slot $after1"
[ "$after1" = "B" ] || { echo "ERROR: expected slot B after cycle 1, got '$after1'"; exit 1; }

echo "=== Cycle 2: install bundle v3, expect flip back to A ($(date)) ==="
publish_manifest 3
apply_update_and_wait 3
after2=$(read_slot)
echo "After cycle 2: slot $after2"
[ "$after2" = "A" ] || { echo "ERROR: expected slot A after cycle 2, got '$after2'"; exit 1; }

# Clean shutdown
$SSH poweroff || true
kill_qemu

echo "=== A/B update test passed: A -> B -> A ($(date)) ==="
