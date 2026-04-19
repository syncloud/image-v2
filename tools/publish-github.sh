#!/bin/sh -e

# Publish built image + RAUC bundle to the syncloud/image-v2 GitHub release
# for the current DRONE_TAG. Requires GITHUB_TOKEN in env.
#
# Usage: ./tools/publish-github.sh

: "${DRONE_TAG:?DRONE_TAG must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

gh release create "$DRONE_TAG" \
    --repo syncloud/image-v2 \
    --title "$DRONE_TAG" \
    --notes "$DRONE_TAG" 2>/dev/null || true

for i in 1 2 3; do
    echo "attempt $i"
    if timeout 600 gh release upload "$DRONE_TAG" \
        --repo syncloud/image-v2 \
        --clobber output/*.xz output/*.raucb; then
        exit 0
    fi
    sleep 10
done

echo "ERROR: gh release upload failed after 3 attempts" >&2
exit 1
