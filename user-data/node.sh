#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Arbitrum node initialization (Arbitrum Nitro, single Docker container).
#
# Protocol-level setup only — no client version/flags live here. The Nitro
# image tag and the per-network chain id / feed / sequencer URLs come from the
# configuration marker (/opt/blueprints/configurations/$CLIENT_CONFIG), read
# below as the single source of truth. node.sh branches on BC_NETWORK:
#   mainnet : Arbitrum One     chainId 42161,  L1 = Ethereum mainnet
#   nova    : Arbitrum Nova    chainId 42170,  L1 = Ethereum mainnet (AnyTrust)
#   testnet : Arbitrum Sepolia chainId 421614, L1 = Ethereum Sepolia
# All three chains are built into Nitro, so --chain.id loads their chain
# config; no chain-info or genesis file is downloaded.

set -euo pipefail

echo "Starting Arbitrum node setup..."

# Source environment variables written by the framework
source /etc/cdk_environment

# --- Validate required variables (fail closed) ---
if [ -z "${BC_NETWORK:-}" ]; then
    echo "ERROR: BC_NETWORK is not set" >&2
    exit 1
fi
if [ -z "${CLIENT_CONFIG:-}" ]; then
    echo "ERROR: CLIENT_CONFIG is not set" >&2
    exit 1
fi
if [ -z "${ARBITRUM_L1_RPC_URL:-}" ] || [ "${ARBITRUM_L1_RPC_URL}" = "https://your-ethereum-l1-rpc-url" ]; then
    echo "ERROR: ARBITRUM_L1_RPC_URL is not set or still has the placeholder value" >&2
    exit 1
fi
if [ -z "${ARBITRUM_L1_BEACON_URL:-}" ] || [ "${ARBITRUM_L1_BEACON_URL}" = "https://your-ethereum-l1-beacon-url" ]; then
    echo "ERROR: ARBITRUM_L1_BEACON_URL is not set or still has the placeholder value" >&2
    exit 1
fi

case "$BC_NETWORK" in
    mainnet|nova|testnet) ;;
    *) echo "ERROR: unsupported BC_NETWORK '$BC_NETWORK' (expected 'mainnet', 'nova' or 'testnet')" >&2; exit 1 ;;
esac

# Ports (framework-provided with blueprint defaults)
RPC_PORT="${ARBITRUM_RPC_PORT:-8547}"
WS_PORT="${ARBITRUM_WS_PORT:-8548}"
METRICS_PORT="${ARBITRUM_METRICS_PORT:-6070}"

# --- Get EC2 internal IP (RPC/WS bind here, never 0.0.0.0) ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
EC2_INTERNAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
if [ -z "$EC2_INTERNAL_IP" ]; then
    echo "ERROR: could not resolve EC2 internal IP from IMDS" >&2
    exit 1
fi
echo "EC2 Internal IP: $EC2_INTERNAL_IP"
echo "Network: $BC_NETWORK"
echo "Client Configuration: $CLIENT_CONFIG"

# --- Read the configuration marker (single source of truth) ---
CONFIG_FILE="/opt/blueprints/configurations/${CLIENT_CONFIG}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: configuration marker not found: $CONFIG_FILE" >&2
    exit 1
fi

cfg() {
    # Read a "key: value" scalar from the YAML marker (quotes optional).
    grep -E "^$1:" "$CONFIG_FILE" | head -n1 | sed -E "s/^$1:[[:space:]]*\"?([^\"]+)\"?.*/\1/"
}

NITRO_IMAGE="$(cfg nitro_image)"
HTTP_API="$(cfg http_api)"
WS_API="$(cfg ws_api)"
if [ -z "$NITRO_IMAGE" ] || [ "$NITRO_IMAGE" = "latest" ] || printf '%s' "$NITRO_IMAGE" | grep -q ':latest$' || ! printf '%s' "$NITRO_IMAGE" | grep -q ':'; then
    echo "ERROR: nitro_image must be a pinned immutable tag (got '$NITRO_IMAGE')" >&2
    exit 1
fi

# BC_NETWORK is also the key prefix in the marker (mainnet_*, nova_*, testnet_*).
CHAIN_ID="$(cfg "${BC_NETWORK}_chain_id")"
FEED_URL="$(cfg "${BC_NETWORK}_feed_url")"
SEQUENCER_URL="$(cfg "${BC_NETWORK}_sequencer_url")"
if [ -z "$CHAIN_ID" ] || [ -z "$FEED_URL" ] || [ -z "$SEQUENCER_URL" ]; then
    echo "ERROR: configuration marker is missing ${BC_NETWORK}_chain_id / _feed_url / _sequencer_url" >&2
    exit 1
fi
echo "Chain ID: $CHAIN_ID"

# --- Install Docker if not present (host is Ubuntu 24.04) ---
# Idempotent: skips the apt repo setup when docker is already on PATH, so a
# re-run (or a boot where the AMI already ships docker) is a no-op.
if ! command -v docker &> /dev/null; then
    echo "Installing Docker (Ubuntu)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "Docker is already installed"
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKER_EOF'
{
  "log-driver": "syslog",
  "log-opts": {
    "syslog-address": "unixgram:///dev/log",
    "tag": "{{.Name}}"
  }
}
DOCKER_EOF
systemctl enable docker
systemctl restart docker

# bcuser owns the data and runs the service
usermod -aG docker bcuser
mkdir -p /data/nitro
chown -R bcuser:bcuser /data /home/bcuser

# Nitro's database lives in <persistent.chain>/nitro, i.e. /data/nitro/nitro
# on the host (the container mounts /data/nitro at /data).
NITRO_INSTANCE_DIR="/data/nitro/nitro"

# --- Database snapshot ------------------------------------------------------
# Arbitrum One cannot sync from genesis (its pre-Nitro Classic history is not
# replayable), and for every chain a snapshot avoids weeks of replay and the
# archive-grade L1 a from-genesis sync would need. Two ways in:
#
# 1. Default: --init.latest=pruned. Nitro reads
#    https://snapshot.arbitrum.foundation/<chain>/latest-pruned.txt (arb1,
#    nova, sepolia-rollup), which names the newest pruned (HashDB) snapshot
#    DIRECTORY, then reads <dir>/.manifest.txt, downloads every ~500 GB part,
#    verifies each sha256, joins and extracts them. No dated URL to maintain.
# 2. ARBITRUM_SNAPSHOT_URL: pin a specific pruned snapshot from
#    https://snapshot-explorer.arbitrum.io/. Use the snapshot DIRECTORY URL
#    with a trailing slash, e.g.
#      https://snapshot.arbitrum.foundation/arb1/2026-10-05-e53f3033/
#    Pointing --init.url at a single pruned.tar.partNNNN file is a trap: each
#    part has its own .sha256, so Nitro accepts it as a complete archive and
#    fails extracting it with "unexpected EOF". A part-file URL is therefore
#    rewritten to its directory below.
#
# Disk: Nitro holds the downloaded parts and the joined archive at the same
# time, then the archive and the extracted database, so the restore needs ~2x
# the snapshot size free on /data. Nitro ignores these flags once a database
# exists, so they are harmless on later restarts.
SNAPSHOT_URL="${ARBITRUM_SNAPSHOT_URL:-}"
if [ -n "$SNAPSHOT_URL" ]; then
    case "$SNAPSHOT_URL" in
        https://*) ;;
        *) echo "ERROR: refusing non-HTTPS ARBITRUM_SNAPSHOT_URL '$SNAPSHOT_URL'" >&2; exit 1 ;;
    esac
    case "$SNAPSHOT_URL" in
        *.tar.part[0-9][0-9][0-9][0-9])
            SNAPSHOT_URL="${SNAPSHOT_URL%/*}/"
            echo "ARBITRUM_SNAPSHOT_URL pointed at one snapshot part; using its directory: ${SNAPSHOT_URL}"
            ;;
        */) ;;
        *)
            echo "WARNING: ARBITRUM_SNAPSHOT_URL has no trailing slash; Nitro needs the directory URL for multi-part snapshots" >&2
            ;;
    esac
    echo "Snapshot: pinned ${SNAPSHOT_URL}"
    # systemd treats '%' as a specifier in unit files; escape any URL-encoded
    # characters ('%' -> '%%').
    INIT_ARG="--init.url=$(printf '%s' "$SNAPSHOT_URL" | sed 's/%/%%/g')"
else
    echo "Snapshot: latest pruned snapshot via --init.latest"
    INIT_ARG="--init.latest=pruned"
fi

# Go runtime soft memory limit (Arbitrum docs: node tuning), 75% of RAM.
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
GOMEMLIMIT_MIB=$(( MEM_TOTAL_KB * 3 / 4 / 1024 ))
echo "GOMEMLIMIT: ${GOMEMLIMIT_MIB}MiB"

chown -R bcuser:bcuser /data

# --- systemd service: name MUST be "node"; container runs the pinned image ---
# RPC/WS bind to the EC2 internal IP (not 0.0.0.0); metrics bind to
# 127.0.0.1. A non-sequencing full node needs no inbound P2P port: it reads
# the sequencer feed over an outbound websocket and the parent chain over L1.
#
# ExecStartPre (+ = runs as root): if a previous start died mid-download,
# Nitro leaves <instance>/tmp behind and then refuses to start with "tmp
# directory for downloading init file already exists". Clear it only while no
# database exists yet.
cat > /etc/systemd/system/node.service <<EOF
[Unit]
Description=Arbitrum Nitro Node (${BC_NETWORK}, chain ${CHAIN_ID})
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
User=bcuser
Group=bcuser
Restart=always
RestartSec=30
TimeoutStartSec=0
TimeoutStopSec=330
EnvironmentFile=/etc/cdk_environment
ExecStartPre=-/usr/bin/docker rm -f arbitrum-nitro
ExecStartPre=+/bin/sh -c 'if [ -d ${NITRO_INSTANCE_DIR}/tmp ] && [ ! -d ${NITRO_INSTANCE_DIR}/l2chaindata ]; then echo "Removing stale snapshot download dir ${NITRO_INSTANCE_DIR}/tmp"; find ${NITRO_INSTANCE_DIR}/tmp -delete; fi'
ExecStart=/usr/bin/docker run --rm --name arbitrum-nitro --network=host \\
  -e GOMEMLIMIT=${GOMEMLIMIT_MIB}MiB \\
  -v /data/nitro:/data \\
  ${NITRO_IMAGE} \\
  --persistent.chain=/data \\
  --persistent.global-config=/data \\
  --chain.id=${CHAIN_ID} \\
  ${INIT_ARG} \\
  --parent-chain.connection.url ${ARBITRUM_L1_RPC_URL} \\
  --parent-chain.blob-client.beacon-url ${ARBITRUM_L1_BEACON_URL} \\
  --parent-chain.connection.retries 10 \\
  --parent-chain.connection.retry-delay 2s \\
  --parent-chain.connection.retry-errors "429|Too Many Requests|connection reset|EOF|timeout" \\
  --node.inbox-reader.min-blocks-to-read 1 \\
  --node.inbox-reader.default-blocks-to-read 10 \\
  --node.inbox-reader.max-blocks-to-read 20 \\
  --node.inbox-reader.check-delay 2s \\
  --node.feed.input.url ${FEED_URL} \\
  --node.staker.enable=false \\
  --execution.forwarding-target ${SEQUENCER_URL} \\
  --http.addr ${EC2_INTERNAL_IP} \\
  --http.port ${RPC_PORT} \\
  --http.vhosts=* \\
  --http.corsdomain=* \\
  --http.api=${HTTP_API} \\
  --http.rpcprefix=/ \\
  --ws.addr ${EC2_INTERNAL_IP} \\
  --ws.port ${WS_PORT} \\
  --ws.api=${WS_API} \\
  --ws.rpcprefix=/ \\
  --metrics \\
  --metrics-server.addr 127.0.0.1 \\
  --metrics-server.port ${METRICS_PORT} \\
  --log-level info
# Graceful shutdown lets Nitro flush its cached state to disk.
ExecStop=/usr/bin/docker stop --time=300 arbitrum-nitro

[Install]
WantedBy=multi-user.target
EOF

# The container writes chain data under /data (mounted from the host's
# /data/nitro). The nitro image runs as a non-root uid (1000); make it writable.
chmod -R 777 /data/nitro

# Pre-pull the pinned image (with retries) so the service starts promptly
# instead of crash-looping while a cold pull is in flight.
echo "Pulling ${NITRO_IMAGE} ..."
for attempt in 1 2 3 4 5; do
    if docker pull "${NITRO_IMAGE}"; then
        echo "Image pulled"
        break
    fi
    echo "Pull attempt ${attempt} failed; retrying in 15s..."
    sleep 15
done

systemctl daemon-reload
systemctl enable node.service
systemctl start node.service

echo "Arbitrum node service started"

# Sentinel for the framework/health tooling
touch /data/init-completed
echo "Arbitrum node setup completed successfully"
