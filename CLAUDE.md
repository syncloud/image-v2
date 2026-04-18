# Debugging CI failures

When a CI build fails, always start by identifying the failing step:
```
curl -s "http://ci.syncloud.org:8080/api/repos/syncloud/image-v2/builds/{N}" | python3 -c "
import json,sys
b=json.load(sys.stdin)
for stage in b.get('stages',[]):
    for step in stage.get('steps',[]):
        if step.get('status') == 'failure':
            print(step.get('name'), '-', step.get('status'))
"
```

Then get the step log (stage=pipeline index, step=step number):
```
curl -s "http://ci.syncloud.org:8080/api/repos/syncloud/image-v2/builds/{N}/logs/{stage}/{step}" | python3 -c "
import json,sys; [print(l.get('out',''), end='') for l in json.load(sys.stdin)]
" | tail -80
```

For running/stuck steps (logs not flushed to DB yet), use the stream API:
```
timeout 5 curl -s -N "http://ci.syncloud.org:8080/api/stream/syncloud/image-v2/{N}/{stage}/{step}" | grep "^data:" | tail -10 | python3 -c "
import json,sys
for line in sys.stdin:
    if line.strip().startswith('data: '):
        try: print(json.loads(line.strip()[6:]).get('out',''), end='')
        except: pass
"
```

# CI

http://ci.syncloud.org:8080/syncloud/image-v2

CI is Drone CI (JS SPA). Check builds via API:

## CI Runners

Runner IPs are in `.runner` file (git-ignored). Source it to get `ARM64_RUNNER` / `AMD64_RUNNER` variables.
- arm64 runner runs all arm64 board builds (odroid-n2, odroid-hc4, raspberrypi-64)
- amd64 runner runs amd64-uefi builds **and is also the artifact/build server** (hosts `ci.syncloud.org:8081`)
- Check uptime: `ssh root@$ARM64_RUNNER uptime`
- Check reboots: `ssh root@$ARM64_RUNNER last reboot | head -5`
```
curl -s "http://ci.syncloud.org:8080/api/repos/syncloud/image-v2/builds?limit=5"
```

## CI Artifacts

Artifacts are served at `http://ci.syncloud.org:8081` (returns JSON directory listings).
The files are physically stored on the amd64 runner under `/data/artifact/repo/` — SSH to
`$AMD64_RUNNER` and work with them directly instead of downloading to the local machine.

Examples:
- Image artifacts: `/data/artifact/repo/image-v2/<build>/...`
- Rootfs artifacts: `/data/artifact/repo/rootfs/<build>-<distro>-<arch>/rootfs-<distro>-<arch>.tar.gz`

Browse via HTTP:
```
curl -s "http://ci.syncloud.org:8081/files/image-v2/"
```

## CI Secrets

- `artifact_host` -- hostname/IP of artifact server
- `artifact_key` -- SSH private key for `artifact` user
- `github_token` -- GitHub PAT for release uploads (tag events only)

# Project Structure

- **Self-updating image builder** for Syncloud using Armbian + RAUC A/B atomic updates
- Builds bootable `.img` files for 4 boards with A/B rootfs partitions
- CI pipelines defined in `.drone.jsonnet` (4 parallel board builds)
- Uses `kpartx` (not `losetup --partscan`) for partition device nodes in Docker

## Key files

- `.drone.jsonnet` -- Drone CI pipeline definitions (4 parallel board builds)
- `boards/*/board.conf` -- Per-board configuration (arch, bootloader, Armbian URL, RAUC compatible string)
- `tools/build-arm64.sh` -- Download Armbian + repartition for A/B layout
- `tools/build-amd64.sh` -- Build amd64 UEFI image with debootstrap + A/B layout
- `tools/repartition-ab.sh` -- Convert Armbian 2-partition to A/B 4-partition layout
- `tools/build-bundle.sh` -- Create signed RAUC OTA update bundles
- `tools/gen-keys.sh` -- One-time RAUC signing key generation
- `tools/cleanup.sh` -- Free stale loop devices after build (runs as CI cleanup step)
- `rauc/system.conf` -- RAUC system config template (@RAUC_COMPATIBLE@, @BOOTLOADER@ placeholders)
- `rauc/grub.cfg` -- GRUB A/B boot selection (amd64)
- `rauc/uboot-boot.cmd` -- U-Boot A/B boot script (arm64)
- `update-agent/` -- Device-side OTA update service (systemd timer, checks every 6h)

## Build pipeline steps (per board)

1. `build` -- Build image (download Armbian or debootstrap, repartition for A/B)
2. `bundle` -- Create signed RAUC update bundle (tag events only)
3. `publish to github` -- Upload to GitHub release (tag events only)
4. `artifact` -- Upload to artifact server via SCP
5. `cleanup` -- Free stale loop devices (always runs)

## Boards

- raspberrypi-64 (arm64, Armbian, u-boot)
- odroid-hc4 (arm64, Armbian, u-boot)
- odroid-n2 (arm64, Armbian, u-boot)
- amd64-uefi (amd64, debootstrap, grub)

## Armbian partition layouts

Armbian images have different partition layouts per board:
- **2-partition** (e.g. Raspberry Pi): p1=vfat boot (firmware), p2=ext4 rootfs
- **1-partition** (e.g. ODROID HC4, N2): p1=ext4 rootfs with /boot inside, U-Boot in raw sectors 1-8191

For single-partition boards, kernel/initrd/dtb are loaded from the rootfs partition
(the U-Boot boot script loads from `/boot/vmlinuz` on the rootfs). The vfat boot
partition only needs `boot.scr`.

## Build quirks

- Debian bookworm's `debootstrap` doesn't know Ubuntu Noble -- needs `ln -sf gutsy /usr/share/debootstrap/scripts/noble`
- Ubuntu Noble's `rauc` package is in the `universe` repository, not `main`
- `linux-firmware` package is ~634MB -- amd64 rootfs partitions need 4GB+ to fit everything
- arm64 chroot doesn't work on amd64 builder (Exec format error) -- use `dpkg-deb -x` to extract .deb files directly instead of `chroot apt-get install`
- vfat boot partitions can't hold symlinks -- use `cp -rL --no-preserve=ownership`
- All build scripts have `trap cleanup EXIT` to free loop devices on failure

# v1 vs v2 Architecture

## v1 (syncloud/image + syncloud/rootfs)

1. `syncloud/rootfs` builds a rootfs per CPU arch -- installs snapd (syncloud fork) + platform snap
2. `syncloud/base-image` provides vendor board images
3. `syncloud/image` extracts base image, creates boot partition, overlays rootfs, compresses
4. Single rootfs partition, no built-in OTA for the OS itself
5. snapd handles app updates (platform snap, user-installed app snaps)

## v2 (syncloud/image-v2)

1. Downloads pre-built Armbian (ARM) or uses debootstrap (amd64)
2. Repartitions into A/B layout: `boot + rootfs-a + rootfs-b + data`
3. Installs RAUC for atomic OS updates + update agent (systemd timer, checks every 6h)
4. RAUC handles OS-level updates (kernel, base system); snapd handles app updates
5. Auto-rollback: if boot fails 3 times, switches to the other rootfs slot

# Syncloud Device Filesystem Layout (observed on v1 device)

## Partition layout (v1, single rootfs)
```
mmcblk0p1  256M  boot (vfat)
mmcblk0p2  ~30G  rootfs (ext4, mounted at /)
sda        ext   external disk (mounted at /opt/disk/external)
```

## v2 target layout (A/B)
```
p1  boot     (vfat) -- firmware/boot.scr
p2  rootfs-a (ext4) -- active OS + snapd + platform
p3  rootfs-b (ext4) -- inactive OS (written by RAUC during update)
p4  data     (ext4) -- persistent user data (survives A/B switch)
```

## Snap filesystem structure

Snap packages (`.snap` files) are squashfs images mounted as loop devices:
```
/var/lib/snapd/snaps/platform_2643.snap  -> /snap/platform/2643 (ro, loop mount)
/var/lib/snapd/snaps/paperless_175.snap  -> /snap/paperless/175 (ro, loop mount)
```

Snap data directories (read-write, per-version + common):
```
/var/snap/[app]/current -> [version]   (symlink to active version)
/var/snap/[app]/[version]/             (version-specific data)
/var/snap/[app]/common/                (shared across versions)
```

## Storage layout
```
/data -> /opt/disk/external            (symlink, points to external disk if present)
/opt/disk/internal/                    (on-device storage)
/opt/disk/external/                    (external USB/SATA disk, e.g. btrfs)
```

Apps may store data on external storage under `/opt/disk/external/`.

## What lives on rootfs (affected by A/B switch)
- `/var/lib/snapd/snaps/*.snap` -- snap package files
- `/var/lib/snapd/state.json` -- snapd state (installed snaps, channels, etc.)
- `/var/snap/*/` -- snap runtime data (configs, databases, etc.)
- `/snap/*/` -- snap mount points

## What survives A/B switch (on separate partitions/disks)
- `/opt/disk/external/` -- external disk (separate block device)
- Data partition (p4) -- can be mounted at a fixed path

## A/B update concern: snap and app data preservation

When RAUC writes a new rootfs to the inactive slot, everything on that partition is
replaced. On reboot to the new slot, snap packages and their data from the old slot
would be lost unless preserved.

**Solution: move snapd state and snap data to the persistent data partition (p4).**

The data partition survives A/B switches. Bind-mount or symlink:
- `/var/lib/snapd` -> `/data-part/snapd/` (snap packages + state)
- `/var/snap` -> `/data-part/snap-data/` (app runtime data)

This way snapd state, installed snaps, and all app data persist across OS updates.
The RAUC update only replaces the base OS (kernel, system packages, rauc, snapd binary).
snapd on the new rootfs finds its state on the data partition and continues normally.

# CI pipeline config

Drone CI reads `.drone.jsonnet` directly -- there is no need to generate or commit `.drone.yml`.

# Conventions

- Prefer calling scripts from `tools/` in CI steps instead of inlining shell commands in `.drone.jsonnet`.
