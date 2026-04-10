#!/bin/bash -ex

# Build an arm64 image by downloading pre-built Armbian + RAUC A/B layout
# Usage: ./tools/build-arm64.sh <board-dir>
# Example: ./tools/build-arm64.sh boards/raspberrypi-64

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
if [[ -z "$BOARD_DIR" || ! -f "$BOARD_DIR/board.conf" ]]; then
    echo "Usage: $0 <board-dir>"
    exit 1
fi

source "$BOARD_DIR/board.conf"

OUTPUT_DIR="$ROOT/output"
WORK_DIR="$ROOT/build/$(basename "$BOARD_DIR")"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# Download pre-built Armbian minimal image
ARMBIAN_IMAGE="$WORK_DIR/armbian.img"
if [[ ! -f "$ARMBIAN_IMAGE" ]]; then
    echo "Downloading Armbian image: $ARMBIAN_IMAGE_URL"
    wget -O "$WORK_DIR/armbian.img.xz" "$ARMBIAN_IMAGE_URL" --progress=dot:giga
    xz -d "$WORK_DIR/armbian.img.xz"
fi

echo "Base image: $ARMBIAN_IMAGE"

# Repartition for A/B layout
"$ROOT/tools/repartition-ab.sh" "$ARMBIAN_IMAGE" "$BOARD_DIR" "$OUTPUT_DIR"
