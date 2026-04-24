#!/bin/sh -e

: "${DRONE_TAG:?DRONE_TAG must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

GH_VERSION=2.65.0
ARCH=$(dpkg --print-architecture)
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar
curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /tmp
GH="/tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh"

"$GH" release create "$DRONE_TAG" \
    --repo syncloud/image-v2 \
    --title "$DRONE_TAG" \
    --notes "$DRONE_TAG" 2>/dev/null || true

for i in 1 2 3; do
    echo "attempt $i"
    if timeout 600 "$GH" release upload "$DRONE_TAG" \
        --repo syncloud/image-v2 \
        --clobber output/*.xz output/*.raucb; then
        exit 0
    fi
    sleep 10
done

echo "ERROR: gh release upload failed after 3 attempts" >&2
exit 1
