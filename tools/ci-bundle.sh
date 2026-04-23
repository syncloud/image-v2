#!/bin/bash -e

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
VERSION=$2
: "${BOARD_DIR:?usage: $0 <board-dir> <version>}"
: "${VERSION:?usage: $0 <board-dir> <version>}"
: "${RAUC_SIGNING_KEY:?RAUC_SIGNING_KEY must be set (Drone secret rauc_signing_key)}"

mkdir -p "$ROOT/rauc/keys"
printf '%s' "$RAUC_SIGNING_KEY" > "$ROOT/rauc/keys/key.pem"
chmod 600 "$ROOT/rauc/keys/key.pem"

"$ROOT/tools/build-bundle.sh" "$BOARD_DIR" "$VERSION"
