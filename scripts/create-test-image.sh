#!/bin/bash
# Create a DISPOSABLE test disk image for safe copy trials.
# Never point this at your real drive: it creates a fresh sparse image
# under /tmp and mounts it, so the copy engine can be exercised with
# zero risk to existing data.
set -euo pipefail
IMG="/tmp/ntfsbridge-test.sparseimage"
VOLNAME="NTFSBRIDGE-TEST"
rm -f "$IMG"
hdiutil create -size 2g -type SPARSE -fs ExFAT -volname "$VOLNAME" "$IMG"
hdiutil attach "$IMG" -mountpoint "/Volumes/$VOLNAME"
echo "Mounted disposable test volume at /Volumes/$VOLNAME"
echo "Copy test folders there from NTFS Bridge, then:"
echo "  hdiutil detach /Volumes/$VOLNAME && rm $IMG"
