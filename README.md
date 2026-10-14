# Sample AWS Blockchain Node Runner app for Arbitrum

| Contributed by |
|:--------------------:|
| [@karimakacem](https://github.com/karimakacem) |

[Arbitrum](https://arbitrum.io/) is a family of Ethereum layer-2 chains run by
[Arbitrum Nitro](https://github.com/OffchainLabs/nitro). This blueprint deploys
an Arbitrum full node on AWS for one of three chains:

| `BC_NETWORK` | Chain | Chain ID | Parent chain |
|---|---|---|---|
| `mainnet` | Arbitrum One (Rollup) | `42161` | Ethereum mainnet |
| `nova` | Arbitrum Nova (AnyTrust) | `42170` | Ethereum mainnet |
| `testnet` | Arbitrum Sepolia (Rollup) | `421614` | Ethereum Sepolia |

> This blueprint deploys an RPC full node. It does **not** configure a
> validator, sequencer, batch poster or archive node. The staker is disabled
> and transactions are forwarded to the chain's public sequencer.

## Overview of Deployment Architectures

### Single Node

A single EC2 instance runs the `offchainlabs/nitro-node` container (host
networking) with an EBS `gp3` data volume mounted at `/data`. RPC/WS bind to
the instance's internal IP and metrics to `127.0.0.1`. The node follows the
sequencer feed over an outbound websocket and reads the parent chain through
the L1 execution + beacon endpoints you provide. Good for development and
testing.

### Highly Available (HA) Nodes

Multiple nodes run behind an internal Application Load Balancer in an Auto
Scaling Group. The ALB health-checks each node's RPC port and routes only to
nodes that are serving. Suitable for production RPC serving. Arbitrum
recommends a [feed relay](https://docs.arbitrum.io/run-a-node/run-feed-relay)
when running several nodes; this blueprint connects each node to the public
feed directly.

## Supported Configurations

| Option | Value |
|---|---|
| Client | Arbitrum Nitro (`offchainlabs/nitro-node:v3.12.1-70fa99a`, amd64 + arm64) |
| Networks | `mainnet` (Arbitrum One), `nova` (Arbitrum Nova), `testnet` (Arbitrum Sepolia) |
| Deployment modes | `single-node`, `ha-nodes` |
| Default configuration | `nitro-v3.12.1-full.yml` |
| State scheme | HashDB (Nitro default), restored from the `pruned` snapshot |

## Infrastructure Requirements

Arbitrum's [minimum full-node hardware](https://docs.arbitrum.io/run-a-node/start-here#minimum-hardware-configuration)
is 64 GB RAM and 8 cores (recommended: 128 GB, 16 cores).

| Resource | Recommendation |
|---|---|
| Instance (x86_64) | `r6i.2xlarge` (8 vCPU, 64 GB); `r6i.4xlarge` for heavy RPC load |
| Instance (ARM_64) | `r7g.2xlarge` |
| Storage | `gp3`, 16000 IOPS / 1000 MiB/s for One and Sepolia. Size: One 5500 GiB, Sepolia 4500 GiB, Nova 1500 GiB (the snapshot restore needs ~2x the snapshot size; see [Database Snapshots](#database-snapshots)) |
| Ports | 8547 (RPC), 8548 (WS), 6070 (metrics) — all VPC-internal; no inbound P2P port |

### Prerequisites

- An Ethereum L1 **execution RPC** endpoint and an L1 **beacon** endpoint for
  the parent chain: Ethereum mainnet for `mainnet` and `nova`, Sepolia for
  `testnet`. The samples default to free, keyless public endpoints, and the
  node is configured to tolerate their rate limits.
- Nitro fetches batch blobs itself from
  `<beacon>/eth/v1/beacon/blobs/{slot}`, so the beacon endpoint must serve that
  route. No blob proxy is used on any network. A beacon keeps blobs for about
  18 days, so restore from a snapshot younger than that (the published
  snapshots are refreshed every 1-2 weeks).

> **Tip:** run the deployment commands from AWS CloudShell, which already has
> AWS credentials and the required tooling.

## Setup Instructions

> For general setup (clone, install, bootstrap), follow the Node Runners
> [Getting Started](https://aws-samples.github.io/aws-blockchain-node-runners/docs/getting-started/quickstart)
> guide, then install this blueprint:
>
> ```bash
> npm install github:karimakacem/aws-bnr-blueprint-arbitrum --legacy-peer-deps
> ```

### Step 1: Configure Environment

```bash
cp blueprints/arbitrum/samples/.env-testnet-nitro-full .env
# Edit AWS_ACCOUNT_ID, AWS_REGION, and (optionally) the ARBITRUM_L1_* endpoints
```

### Step 2: Choose Configuration

| Sample | Network | Mode | Instance | Data volume |
|---|---|---|---|---|
| `.env-testnet-nitro-full` | Arbitrum Sepolia | single-node | `r6i.2xlarge` | 4500 GiB |
| `.env-mainnet-nitro-full` | Arbitrum One | single-node | `r6i.2xlarge` | 5500 GiB |
| `.env-mainnet-nitro-full-ha` | Arbitrum One | ha-nodes | `r6i.2xlarge` | 5500 GiB |
| `.env-nova-nitro-full` | Arbitrum Nova | single-node | `r6i.2xlarge` | 1500 GiB |

### Step 3: Deploy

```bash
npx cdk deploy --json --outputs-file deploy-output.json
```

> **AI Alternative:** you can also deploy with the `@deploy` AI prompt, which
> reads your `.env` and runs the deployment workflow for you.

### Step 4: Monitor Deployment

```bash
export INSTANCE_ID=$(jq -r '..|.InstanceId? | select(. != null)' deploy-output.json)
aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
sudo systemctl status node
sudo journalctl -u node -f
# Snapshot restore progress: "Downloading database part", "Joined database
# part into archive", "extracting downloaded init archive".
df -h /data
```

### Step 5: Verify Node Operation

```bash
# From the instance (RPC binds to the internal IP):
IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://$IP:8547"
# 0xa4b1 (One), 0xa4ba (Nova), 0x66eee (Sepolia)
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  "http://$IP:8547"
# A fully synced node returns {"result":false}.
```

## Configuration Options

| Variable | Description | Default |
|---|---|---|
| `BC_NETWORK` | `mainnet` (One), `nova` or `testnet` (Sepolia) | — |
| `ARBITRUM_L1_RPC_URL` | Parent-chain execution RPC (required) | — |
| `ARBITRUM_L1_BEACON_URL` | Parent-chain beacon API (required) | — |
| `ARBITRUM_SNAPSHOT_URL` | Pin a snapshot directory URL instead of the latest | unset (`--init.latest=pruned`) |
| `ARBITRUM_RPC_PORT` | JSON-RPC port | `8547` |
| `ARBITRUM_WS_PORT` | WebSocket port | `8548` |
| `ARBITRUM_METRICS_PORT` | Metrics port | `6070` |

The chain id, sequencer feed and forwarding target per network are set in
`configurations/nitro-v3.12.1-full.yml`. All three chains are built into
Nitro, so `--chain.id` also loads their rollup addresses, the Arbitrum One
backup feeds and the Nova AnyTrust DAS mirrors; nothing is downloaded at boot
besides the image and the snapshot.

## Database Snapshots

Offchain Labs publishes pruned Nitro database snapshots for all three chains
([snapshot explorer](https://snapshot-explorer.arbitrum.io/)). Arbitrum One
**must** start from a snapshot: its pre-Nitro (Classic) history cannot be
replayed. For Nova and Sepolia a snapshot avoids weeks of replay and the
archive-grade L1 endpoint a from-genesis sync would need.

- **Default: `--init.latest=pruned`.** Nitro reads
  `https://snapshot.arbitrum.foundation/<arb1|nova|sepolia-rollup>/latest-pruned.txt`,
  which names the newest snapshot directory, then downloads every part listed
  in its `.manifest.txt`, verifies each SHA-256, joins and extracts them
  ([Nitro database snapshots](https://docs.arbitrum.io/run-a-node/nitro/nitro-database-snapshots)).
  There is no dated URL to keep current.
- **Pinning:** set `ARBITRUM_SNAPSHOT_URL` to a snapshot **directory** URL with
  a trailing slash, e.g.
  `https://snapshot.arbitrum.foundation/arb1/2026-10-05-e53f3033/`. Do not
  point it at a `pruned.tar.partNNNN` file: a single part passes its own
  checksum but fails extraction with `unexpected EOF`. `node.sh` rewrites a
  part URL to its directory for you.
- **Size the data volume for ~2x the snapshot.** Nitro keeps the downloaded
  parts until the joined archive is written, then keeps the archive until the
  database is extracted. Sizes at the time of writing:

| Chain | Pruned snapshot | Size | 2x | Sample volume |
|---|---|---|---|---|
| Arbitrum One | 2026-10-05, 5 parts | 2485 GiB (2.67 TB) | 4971 GiB | 5500 GiB |
| Arbitrum Sepolia | 2026-10-02, 4 parts | 1782 GiB (1.91 TB) | 3564 GiB | 4500 GiB |
| Arbitrum Nova | 2026-09-08, 2 parts | 582 GiB (0.62 TB) | 1164 GiB | 1500 GiB |

  Check the current size with
  `curl -s "https://snapshot.arbitrum.foundation/$(curl -s https://snapshot.arbitrum.foundation/arb1/latest-pruned.txt)metadata.json"`
  (substitute `nova` or `sepolia-rollup` for `arb1`)
  before deploying. After the restore the database uses about 1x, and the
  rest of the volume is headroom for growth (EBS volumes cannot shrink).

`SNAPSHOT_ENABLED` (the framework's own S3 snapshot restore) stays `"false"`
for this blueprint.

## Troubleshooting

Primary diagnostics are in CloudWatch Logs and `journalctl`.

- **Node not starting:** `sudo journalctl -u node -n 200`. Check the L1
  endpoints are reachable and not placeholders.
- **`no space left on device` during the restore:** the data volume is
  smaller than ~2x the current snapshot. Grow the EBS volume (and the
  filesystem with `resize2fs`), then `sudo systemctl restart node`; the
  service clears Nitro's partial download directory before retrying.
- **`tmp directory for downloading init file already exists`:** a restore was
  interrupted. The `node` service removes the stale directory on its next
  start while no database exists; `sudo systemctl restart node`.
- **Stuck sync / blob errors:** confirm the beacon serves
  `/eth/v1/beacon/blobs/{slot}` and that the snapshot is younger than the
  beacon's ~18-day blob retention.
- **Metrics not appearing:** confirm the node is up and `ARBITRUM_METRICS_PORT`
  (6070) is being scraped on `127.0.0.1`.
- **Health check failures (HA):** the ALB checks RPC port 8547 and accepts
  `200,400` (Nitro answers a plain `GET /` with 400). The port only opens once
  the snapshot is restored, which for Arbitrum One can exceed the 300-minute
  grace period. If the ASG replaces nodes that are still restoring, suspend
  replacement until they serve, then resume:

  ```bash
  aws autoscaling suspend-processes --auto-scaling-group-name <asg> --scaling-processes ReplaceUnhealthy
  # ...after every node answers on 8547 and the ALB shows every target healthy.
  # A node the ASG marked Unhealthy during the restore keeps that flag even
  # after it starts serving; clear it first, or resuming terminates it:
  aws autoscaling set-instance-health --instance-id <id> --health-status Healthy
  aws autoscaling resume-processes --auto-scaling-group-name <asg> --scaling-processes ReplaceUnhealthy
  ```

See the Node Runners [Troubleshooting Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/troubleshooting) for more.

## Upgrades

- **Upgrade the Nitro client:** bump `nitro_image` in
  `configurations/nitro-v3.12.1-full.yml` (rename the file to the new version)
  via the `@version-update` workflow, then redeploy. Use release versions
  only; Arbitrum does not support running RC builds.
- **Rolling updates (HA):** replace instances one at a time through the Auto
  Scaling Group so RPC capacity is preserved. Each new instance restores a
  fresh snapshot.

## Cost Optimization

- **Storage:** the 2x restore headroom dominates the bill on Arbitrum One
  (5500 GiB gp3). A lower-cost alternative is to stream the snapshot parts
  straight into `tar` on the instance (verifying each part's SHA-256 as it
  streams) and start Nitro on the extracted database, which needs ~1x plus
  growth; this blueprint does not do that yet.
- **Compute:** use the ARM_64 option (`r7g.2xlarge`) for a lower price/perf
  point; right-size after observing real load.
- **Network:** keep the ALB internal unless you must expose RPC publicly.

## Security Considerations

- RPC and WS bind to the instance's internal IP (never `0.0.0.0`); metrics bind
  to `127.0.0.1`.
- The `node` service runs as the non-root `bcuser` (UID/GID 1002); the
  container runs as Nitro's non-root UID 1000.
- Snapshots are fetched over HTTPS only, and Nitro verifies every part's
  SHA-256 from the manifest before extracting.
- The default ALB is internal and restricted to the VPC CIDR; exposing it to the
  internet requires explicitly setting `HA_ALB_INTERNET_FACING` **and**
  `HA_ALB_ALLOWED_CIDR`.
- The Nitro image is pinned to an immutable tag; `node.sh` refuses `latest`.

## FAQ

**Can I run a validator or archive node?** Not with this blueprint. It runs a
non-sequencing, non-staking full node on HashDB.

**Why does Arbitrum One need so much disk?** Its pruned snapshot is ~2.5 TiB,
and the restore needs about twice that free while it joins and extracts.

**Does any network need a blob proxy?** No. Nitro reads blobs directly from the
beacon's `/eth/v1/beacon/blobs/{slot}` route.

## Additional Resources

- [Arbitrum — Run a full node](https://docs.arbitrum.io/run-a-node/run-full-node)
- [Arbitrum — Prepare to run a node](https://docs.arbitrum.io/run-a-node/start-here)
- [Nitro database snapshots](https://docs.arbitrum.io/run-a-node/nitro/nitro-database-snapshots)
- [Arbitrum Nitro releases](https://github.com/OffchainLabs/nitro/releases)

## Support

Open an issue in the [aws-blockchain-node-runners](https://github.com/aws-samples/aws-blockchain-node-runners) repository.

## Maintenance

The client image is pinned to a fixed release. A weekly `release-watch`
workflow compares it with the latest upstream release and opens an issue when
the pin falls behind. To move to a new release:

```bash
scripts/bump.sh --show                                  # current pins
scripts/bump.sh <new-config-file> <image>=<new-tag>     # rename + repin
scripts/validate.sh                                     # tests + cdk synth
```

`scripts/validate.sh` installs this blueprint into a clean Node Runners
checkout, runs the integration tests, and synthesizes every sample. CI runs it
on every push and weekly against Node Runners `main`.
