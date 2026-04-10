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

# CI

http://ci.syncloud.org:8080/syncloud/image-v2

CI is Drone CI (JS SPA). Check builds via API:
```
curl -s "http://ci.syncloud.org:8080/api/repos/syncloud/image-v2/builds?limit=5"
```

## CI Artifacts

Artifacts are served at `http://ci.syncloud.org:8081` (returns JSON directory listings).

Browse artifacts for a build:
```
curl -s "http://ci.syncloud.org:8081/files/image-v2/"
```

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
- `rauc/system.conf` -- RAUC system config template (@RAUC_COMPATIBLE@, @BOOTLOADER@ placeholders)
- `rauc/grub.cfg` -- GRUB A/B boot selection (amd64)
- `rauc/uboot-boot.cmd` -- U-Boot A/B boot script (arm64)
- `update-agent/` -- Device-side OTA update service (systemd timer, checks every 6h)

## Build pipeline steps (per board)

1. `build` -- Build image (download Armbian or debootstrap, repartition for A/B)
2. `bundle` -- Create signed RAUC update bundle (tag events only)
3. `publish to github` -- Upload to GitHub release (tag events only)
4. `artifact` -- Upload to artifact server via SCP

## Boards

- raspberrypi-64 (arm64, Armbian, u-boot)
- odroid-hc4 (arm64, Armbian, u-boot)
- odroid-n2 (arm64, Armbian, u-boot)
- amd64-uefi (amd64, debootstrap, grub)

# CI pipeline config

Drone CI reads `.drone.jsonnet` directly -- there is no need to generate or commit `.drone.yml`.
