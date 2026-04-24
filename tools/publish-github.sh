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

echo "--- gh release create ---"
"$GH" release create "$DRONE_TAG" \
    --repo syncloud/image-v2 \
    --title "$DRONE_TAG" \
    --notes "$DRONE_TAG" || echo "release create returned non-zero (likely already exists, continuing)"

echo "--- output/ contents ---"
ls -la output/
FILES=$(ls output/*.xz output/*.raucb 2>&1 || true)
echo "--- files to upload ---"
echo "$FILES"
[ -n "$FILES" ] || { echo "ERROR: no *.xz or *.raucb files in output/"; exit 1; }

upload_file() {
    f=$1
    for i in 1 2 3; do
        echo "--- uploading $f (attempt $i) ---"
        if "$GH" release upload "$DRONE_TAG" \
            --repo syncloud/image-v2 \
            --clobber "$f"; then
            echo "OK: $f"
            return 0
        fi
        echo "attempt $i for $f failed; sleeping 10s"
        sleep 10
    done
    echo "ERROR: failed to upload $f after 3 attempts"
    return 1
}

for f in $FILES; do
    upload_file "$f"
done

echo "OK: all files uploaded"
