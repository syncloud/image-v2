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
SSH="sshpass -p syncloud ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error -o ConnectTimeout=5 -p $SSH_PORT root@localhost"

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
# update-agent fetches $UPDATE_URL/os/<compatible>/latest.json.
WWW="$WORK_DIR/www"
COMPATIBLE_DIR="$WWW/os/syncloud-amd64-uefi"
mkdir -p "$COMPATIBLE_DIR"
publish_manifest() {
    v=$1
    cp "$WORK_DIR/bundle-v$v.raucb" "$COMPATIBLE_DIR/bundle-v$v.raucb"
    cat > "$COMPATIBLE_DIR/latest.json" <<EOF
{"version": "$v", "url": "http://10.0.2.2:8000/os/syncloud-amd64-uefi/bundle-v$v.raucb"}
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


# --- Helper: log a snapshot of the guest's RAUC + bootloader state ---
# Always runs (success or failure) — useful for retrospective debugging.
dump_state() {
    label=$1
    echo "================ guest state: $label ================"
    echo "--- /proc/cmdline ---"
    $SSH 'cat /proc/cmdline' || true
    echo "--- grubenv (ESP) ---"
    $SSH 'grub-editenv /boot/efi/boot/grub/grubenv list' || true
    echo "--- rauc status ---"
    $SSH 'rauc status --detailed' || true
    echo "--- /etc/syncloud-test-version ---"
    $SSH 'cat /etc/syncloud-test-version 2>/dev/null || echo "(not present)"' || true
    echo "================ end state: $label ================"
}

# --- Helper: trigger update, wait for reboot, reboot back up ---
apply_update_and_wait() {
    expected_version=$1
    echo "--- apply_update_and_wait: expected version=$expected_version ---"
    # Point guest at our mock server. Quote the remote command so the
    # '>' redirect runs on the guest, not the host.
    $SSH "sh -c 'echo UPDATE_URL=http://10.0.2.2:8000 > /etc/default/syncloud-update'"
    # Sanity check: verify the override actually landed on the guest.
    got_url=$($SSH 'cat /etc/default/syncloud-update')
    echo "guest /etc/default/syncloud-update: $got_url"
    [ "$got_url" = "UPDATE_URL=http://10.0.2.2:8000" ] || {
        echo "ERROR: UPDATE_URL override didn't land on guest. got: $got_url"
        return 1
    }
    # Probe guest -> mock server reachability before triggering the update.
    # If SLIRP gateway isn't wired, the agent would silently exit 0 with
    # 'No update available' and the whole test would stall.
    echo "Probing guest connectivity to mock update server..."
    probe_code=$($SSH "curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://10.0.2.2:8000/os/syncloud-amd64-uefi/latest.json" 2>&1) || true
    echo "probe latest.json HTTP code: $probe_code"
    if [ "$probe_code" != "200" ]; then
        echo "ERROR: guest cannot reach mock server at 10.0.2.2:8000 (got '$probe_code')"
        echo "=== python http.server log ==="
        cat "$WORK_DIR/http.log" || true
        echo "=== host-side netstat ==="
        ss -tlnp 2>/dev/null | grep :8000 || true
        return 1
    fi
    # Trigger synchronously — script does `systemctl reboot` at the end,
    # which will tear down SSH. That's fine.
    echo "Triggering syncloud-update.service on guest..."
    $SSH 'systemctl start syncloud-update.service' || true
    # Grab the install journal before QEMU exits. The new slot's rootfs
    # will have an empty journal after reboot, so if we don't capture
    # here we lose all install-side logs.
    echo "=== syncloud-update.service journal (pre-reboot) ==="
    $SSH 'journalctl -u syncloud-update.service --no-pager -n 200' || true
    echo "=== rauc status (pre-reboot) ==="
    $SSH 'rauc status --detailed' || true
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
        dump_state "after-failed-update-trigger"
        echo "=== python http.server log ==="
        cat "$WORK_DIR/http.log" || true
        return 1
    fi
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
    echo "QEMU exited, rebooting VM..."
    boot_and_wait_ssh
    # Always log the state after reboot — easy to see in CI logs whether
    # the slot flipped and what the bootloader actually did.
    dump_state "after-reboot-cycle-v$expected_version"
    # Verify sentinel
    got=$($SSH 'cat /etc/syncloud-test-version 2>/dev/null || echo MISSING')
    if [ "$got" != "version=$expected_version" ]; then
        echo "ERROR: expected sentinel version=$expected_version, got '$got'"
        echo "=== python http.server log ==="
        cat "$WORK_DIR/http.log" || true
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
dump_state "initial-boot"
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

# ---------------------------------------------------------------------------
# Rollback cycle: simulate a broken slot B. Sabotage its kernel, force
# grub to prefer B with 1 retry left, reboot. Expect:
#   boot 1: grub picks B, decrements B_TRY to 0, kernel missing, hangs/fails
#   boot 2: B_TRY=0, B_OK=0 → B not eligible, grub falls back to A
# We host-side kill QEMU after each attempt that doesn't yield SSH and
# restart; after the fallback, SSH comes back on slot A with v3 still.
# ---------------------------------------------------------------------------
echo "=== Rollback cycle: break slot B, expect fallback to A ($(date)) ==="
echo "Sabotaging slot B (remove /vmlinuz and /boot/vmlinuz*)..."
$SSH 'mkdir -p /mnt/sab && mount /dev/disk/by-partlabel/rootfs-b /mnt/sab && rm -f /mnt/sab/vmlinuz /mnt/sab/initrd.img /mnt/sab/boot/vmlinuz* /mnt/sab/boot/initrd.img* && umount /mnt/sab'
echo "Forcing grub to prefer slot B with 1 try (rollback in 2 boots)..."
$SSH 'grub-editenv /boot/efi/boot/grub/grubenv set ORDER="B A" B_OK=0 B_TRY=1'
$SSH 'grub-editenv /boot/efi/boot/grub/grubenv list'
echo "Rebooting — expect grub to try B, fail, fall back to A..."
$SSH 'systemctl reboot' || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# Boot attempt 1: grub picks B (B_TRY=1), decrements to 0, boots a
# missing kernel — VM hangs at GRUB error. We give it 30 s; since it
# won't reach SSH, kill and restart.
echo "Boot attempt 1 (expected hang on broken slot B)..."
qemu-system-x86_64 \
    -enable-kvm -bios "$OVMF" \
    -drive file="$IMAGE",format=raw,if=virtio \
    -m 1024 -smp 2 -nographic -serial "file:$QEMU_LOG" \
    -net nic,model=virtio -net user,hostfwd=tcp::${SSH_PORT}-:22 \
    -no-reboot >/dev/null 2>&1 &
QEMU_PID=$!
sleep 30
if $SSH echo "ssh-ok" >/dev/null 2>&1; then
    echo "ERROR: SSH came up on boot-attempt-1; expected broken-B hang"
    dump_state "unexpected-boot-1"
    exit 1
fi
echo "As expected — no SSH. Killing QEMU to simulate power cycle."
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

# Boot attempt 2: B_TRY=0 and B_OK=0 → grub falls back to A. SSH returns.
echo "Boot attempt 2 (expected fallback to slot A)..."
boot_and_wait_ssh
dump_state "after-rollback"
rollback_slot=$(read_slot)
echo "After rollback: slot $rollback_slot"
[ "$rollback_slot" = "A" ] || { echo "ERROR: rollback expected slot A, got '$rollback_slot'"; exit 1; }
got_sentinel=$($SSH 'cat /etc/syncloud-test-version 2>/dev/null || echo MISSING')
[ "$got_sentinel" = "version=3" ] || { echo "ERROR: rollback expected sentinel version=3 (last A install), got '$got_sentinel'"; exit 1; }

# Clean shutdown
$SSH poweroff || true
kill_qemu

echo "=== A/B update test passed: A -> B -> A + rollback (A) ($(date)) ==="
