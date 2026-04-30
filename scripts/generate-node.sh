#!/usr/bin/env bash
set -euo pipefail

NODE="${1:-}"
ROOT_DIR="${2:-}"
CONTAINER_ENGINE="${3:-}"
EIB_IMAGE="${4:-}"

if [ -z "$NODE" ]; then
  echo "Usage: generate-node.sh <node> <root-dir> <container-engine> <eib-image>" >&2
  exit 1
fi

ENV_FILE="$ROOT_DIR/nodes/$NODE.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

set -a; source "$ENV_FILE"; set +a

WORKDIR="$ROOT_DIR/_network-builds/$NODE"
mkdir -p "$WORKDIR/network" "$WORKDIR/combustion"

envsubst '${NODE_INTERFACE} ${NODE_MAC} ${NODE_IP} ${NODE_PREFIX} ${NODE_GATEWAY} ${NODE_DNS}' \
  < "$ROOT_DIR/templates/nmconnection.tmpl" \
  > "$WORKDIR/network/${NODE_INTERFACE:-eth0}.nmconnection"

envsubst '${NODE_HOSTNAME}' \
  < "$ROOT_DIR/templates/script.tmpl" \
  > "$WORKDIR/combustion/script"
chmod +x "$WORKDIR/combustion/script"

cp "$ROOT_DIR/templates/definition-network.yaml" "$WORKDIR/"

"$CONTAINER_ENGINE" run --rm -i --privileged \
  -v "$WORKDIR":/eib \
  "$EIB_IMAGE" \
  generate --definition-file definition-network.yaml \
  --arch x86_64 --output-type iso --output "$NODE-network.iso"

echo "Generated: _network-builds/$NODE/$NODE-network.iso"
