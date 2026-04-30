#!/bin/bash
# Metal3/Ironic writes the raw image to disk; the partition table does not
# automatically expand to fill the physical disk. This runs once at first boot
# to grow the root filesystem to the full disk size.
set -euo pipefail

/usr/lib/systemd/systemd-growfs /
