#!/bin/bash
# Called by RAUC after writing a slot
# Mark the slot as good after first successful boot

set -e

echo "RAUC post-install: slot ${RAUC_SLOT_NAME} updated"
