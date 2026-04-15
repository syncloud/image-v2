local dind = "20.10.21-dind";

local build(board, arch) = {
    local board_dir = "boards/" + board,
    local tool = if arch == "amd64" then "build-amd64.sh" else "build-arm64.sh",
    kind: "pipeline",
    name: board,

    platform: {
        os: "linux",
        arch: arch
    },
    steps: [
    {
        name: "build",
        image: "debian:bookworm",
        commands: [
            "DEBIAN_FRONTEND=noninteractive apt-get update",
            "DEBIAN_FRONTEND=noninteractive apt-get install -y git bash sudo wget curl gdisk u-boot-tools " +
            "squashfs-tools rauc debootstrap kpartx parted e2fsprogs dosfstools xz-utils",
            "ln -sf gutsy /usr/share/debootstrap/scripts/noble",
            "./tools/" + tool + " " + board_dir,
        ],
        privileged: true
    },
    {
        name: "platform",
        image: "docker:" + dind,
        commands: [
            "./tools/install-platform.sh " + board_dir,
        ],
        volumes: [{
            name: "dockersock",
            path: "/var/run"
        }]
    },
    {
        name: "assemble",
        image: "debian:bookworm",
        commands: [
            "DEBIAN_FRONTEND=noninteractive apt-get update",
            "DEBIAN_FRONTEND=noninteractive apt-get install -y kpartx e2fsprogs xz-utils",
            "echo '=== losetup ==='",
            "LOOP=$(losetup --find --show output/syncloud-" + board + ".img)",
            "echo \"loop: $LOOP\"",
            "echo '=== kpartx ==='",
            "kpartx -avs $LOOP",
            "LOOP_NAME=$(basename $LOOP)",
            "echo '=== mount ==='",
            "mkdir -p /tmp/rootfs",
            "mount /dev/mapper/${LOOP_NAME}p2 /tmp/rootfs",
            "echo '=== tar extract ==='",
            "rm -rf /tmp/rootfs/*",
            "tar -C /tmp/rootfs -xf build/rootfs-platform-" + board + ".tar",
            "echo '=== umount ==='",
            "umount /tmp/rootfs",
            "echo '=== dd clone ==='",
            "dd if=/dev/mapper/${LOOP_NAME}p2 of=/dev/mapper/${LOOP_NAME}p3 bs=4M status=progress",
            "echo '=== e2label ==='",
            "e2label /dev/mapper/${LOOP_NAME}p3 rootfs-b",
            "echo '=== kpartx cleanup ==='",
            "kpartx -d $LOOP",
            "echo '=== losetup cleanup ==='",
            "losetup -d $LOOP",
            "echo '=== xz compress ==='",
            "xz -T0 output/syncloud-" + board + ".img",
            "echo '=== done ==='",
        ],
        privileged: true
    },
    {
        name: "bundle",
        image: "debian:bookworm",
        commands: [
            "DEBIAN_FRONTEND=noninteractive apt-get update",
            "DEBIAN_FRONTEND=noninteractive apt-get install -y squashfs-tools rauc kpartx",
            "./tools/build-bundle.sh " + board_dir + " ${DRONE_TAG:-dev}",
        ],
        privileged: true,
        when: {
            event: ["tag"]
        }
    },
    {
        name: "publish to github",
        image: "maniator/gh:v2.65.0",
        environment: {
            GITHUB_TOKEN: {
                from_secret: "github_token"
            },
        },
        commands: [
            "gh release create ${DRONE_TAG} --repo syncloud/image-v2 --title ${DRONE_TAG} --notes ${DRONE_TAG} 2>/dev/null || true",
            "for i in 1 2 3; do echo \"attempt $i\"; timeout 600 gh release upload ${DRONE_TAG} --repo syncloud/image-v2 --clobber output/*.xz output/*.raucb && break || sleep 10; done",
        ],
        when: {
            event: ["tag"]
        }
    },
    {
        name: "artifact",
        image: "appleboy/drone-scp:1.6.4",
        settings: {
            host: {
                from_secret: "artifact_host"
            },
            username: "artifact",
            key: {
                from_secret: "artifact_key"
            },
            command_timeout: "2m",
            target: "/home/artifact/repo/image-v2",
            source: "output/*"
        }
    },
    {
        name: "cleanup",
        image: "debian:bookworm-slim",
        commands: [
            "./tools/cleanup.sh",
        ],
        privileged: true,
        when: {
            status: ["success", "failure"]
        }
    }],
    services: [{
        name: "docker",
        image: "docker:" + dind,
        privileged: true,
        volumes: [{
            name: "dockersock",
            path: "/var/run"
        }]
    }],
    volumes: [{
        name: "dockersock",
        temp: {}
    }]
};

[
    build(board.name, board.arch)
    for board in [
        { name: "odroid-n2", arch: "arm64" },
        { name: "odroid-hc4", arch: "arm64" },
        { name: "raspberrypi-64", arch: "arm64" },
        { name: "amd64-uefi", arch: "amd64" },
    ]
]
