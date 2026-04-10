#!/bin/bash -ex

# Generate RAUC signing keys (one-time setup)
# The cert.pem goes into the image (keyring), key.pem stays on CI

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

KEY_DIR="$ROOT/rauc/keys"
mkdir -p "$KEY_DIR"

# Generate CA key and certificate
openssl req -x509 -newkey rsa:4096 \
    -keyout "$KEY_DIR/key.pem" \
    -out "$KEY_DIR/cert.pem" \
    -days 3650 \
    -nodes \
    -subj "/O=Syncloud/CN=Syncloud Update Signing Key"

# The cert is also the keyring (self-signed)
cp "$KEY_DIR/cert.pem" "$ROOT/rauc/keyring.pem"

echo "Keys generated in $KEY_DIR"
echo "  key.pem  - KEEP SECRET, use on CI only"
echo "  cert.pem - goes into images as /etc/rauc/keyring.pem"
