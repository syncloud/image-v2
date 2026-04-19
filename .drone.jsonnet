local rootfs_version = "26.04.3";

local build(board, arch) = {
    local board_dir = "boards/" + board,
    local tool = if arch == "amd64" then "tools/build-amd64.sh" else "tools/build-arm64.sh",
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
        environment: {
            ROOTFS_VERSION: rootfs_version,
        },
        commands: [
            "./" + tool + " " + board_dir,
        ],
        privileged: true
    },
    ] + (if arch == "amd64" then [
    {
        name: "test-boot",
        image: "alpine",
        commands: [
            "./tools/test-boot.sh output/syncloud-" + board + ".img.xz",
        ],
        privileged: true
    },
    {
        name: "test-update",
        image: "alpine",
        commands: [
            "./tools/test-update.sh output/syncloud-" + board + ".img.xz",
        ],
        privileged: true
    },
    {
        name: "vdi",
        image: "alpine",
        commands: [
            "./tools/convert-vdi.sh output/syncloud-" + board + ".img.xz",
        ],
    },
    ] else []) + [
    {
        name: "bundle",
        image: "debian:bookworm",
        commands: [
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
            "./tools/publish-github.sh",
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
};

[
    build(board.name, board.arch)
    for board in [
        { name: "amd64-uefi", arch: "amd64" },
        { name: "odroid-n2", arch: "arm64" },
        { name: "odroid-hc4", arch: "arm64" },
        { name: "raspberrypi-64", arch: "arm64" },
    ]
]
