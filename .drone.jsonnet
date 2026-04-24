local rootfs_version = "26.04.6";

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
        image: "debian:bookworm",
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
        environment: {
            RAUC_SIGNING_KEY: {
                from_secret: "rauc_signing_key"
            },
        },
        commands: [
            "./tools/ci-bundle.sh " + board_dir + " ${DRONE_TAG:-dev}",
        ],
        privileged: true,
    },
    {
        name: "publish to github",
        image: "debian:bookworm",
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
        name: "publish to s3",
        image: "debian:bookworm",
        environment: {
            AWS_ACCESS_KEY_ID: {
                from_secret: "aws_access_key_id"
            },
            AWS_SECRET_ACCESS_KEY: {
                from_secret: "aws_secret_access_key"
            },
        },
        commands: [
            "./tools/publish-s3.sh " + board_dir,
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
            command_timeout: "30m",
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
