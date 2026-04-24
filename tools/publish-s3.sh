#!/bin/sh -e

: "${DRONE_TAG:?DRONE_TAG must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

BOARD_DIR=$1
: "${BOARD_DIR:?usage: $0 <board-dir>}"
. "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

BUCKET=updates.syncloud.org
REGION=us-west-2
PREFIX="os/${RAUC_COMPATIBLE}"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq awscli

BUNDLE_LOCAL="output/syncloud-${BOARD_NAME}-${DRONE_TAG}.raucb"
[ -f "$BUNDLE_LOCAL" ] || { echo "ERROR: $BUNDLE_LOCAL not found"; exit 1; }

BUNDLE_KEY="${PREFIX}/${DRONE_TAG}.raucb"
SHA=$(sha256sum "$BUNDLE_LOCAL" | awk '{print $1}')
SIZE=$(stat -c %s "$BUNDLE_LOCAL")

echo "--- uploading bundle ---"
echo "local:  $BUNDLE_LOCAL"
echo "remote: s3://${BUCKET}/${BUNDLE_KEY}"
echo "sha256: $SHA"
echo "size:   $SIZE"

aws s3 cp --region "$REGION" --only-show-errors "$BUNDLE_LOCAL" "s3://${BUCKET}/${BUNDLE_KEY}"

MANIFEST=$(mktemp)
cat > "$MANIFEST" <<EOF
{"version":"${DRONE_TAG}","bundle":"${BUNDLE_KEY}","sha256":"${SHA}","size":${SIZE}}
EOF

echo "--- latest.json ---"
cat "$MANIFEST"

aws s3 cp --region "$REGION" --only-show-errors \
    --content-type application/json \
    --cache-control "no-cache, max-age=0" \
    "$MANIFEST" "s3://${BUCKET}/${PREFIX}/latest.json"

rm -f "$MANIFEST"

echo "--- verifying via HTTPS ---"
curl -fsS "https://s3.${REGION}.amazonaws.com/${BUCKET}/${PREFIX}/latest.json"
echo
