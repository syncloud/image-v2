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
        commands: [
            "DEBIAN_FRONTEND=noninteractive apt-get update",
            "DEBIAN_FRONTEND=noninteractive apt-get install -y wget xz-utils gdisk u-boot-tools kpartx e2fsprogs dosfstools",
            "./" + tool + " " + board_dir,
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
    //{
    //    name: "artifact",
    //    ...
    //},
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
        { name: "odroid-n2", arch: "arm64" },
//        { name: "odroid-hc4", arch: "arm64" },
//        { name: "raspberrypi-64", arch: "arm64" },
//        { name: "amd64-uefi", arch: "amd64" },
    ]
]
