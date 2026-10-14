#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Validate this blueprint against a clean aws-blockchain-node-runners checkout:
#   1. clone Node Runners (or reuse CORE_DIR) and install it
#   2. install this blueprint into its node_modules/ (the community install path)
#   3. run this blueprint's integration tests against the core ConfigurationLoader
#   4. `cdk synth` every sample .env, credential-free
#
# Usage: scripts/validate.sh            # clones into a temp dir
#        CORE_DIR=/path scripts/validate.sh
#        CORE_REF=main scripts/validate.sh
set -euo pipefail

BLUEPRINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$(node -p "require('${BLUEPRINT_DIR}/package.json').name")"
PROTOCOL="$(node -p "require('${BLUEPRINT_DIR}/package.json')['aws-blockchain-node-runner'].BLOCKCHAIN_PROTOCOL")"
CORE_REPO="${CORE_REPO:-https://github.com/aws-samples/aws-blockchain-node-runners.git}"
CORE_REF="${CORE_REF:-main}"

if [[ -z "${CORE_DIR:-}" ]]; then
  CORE_DIR="$(mktemp -d)/aws-blockchain-node-runners"
  git clone --depth 1 --branch "$CORE_REF" "$CORE_REPO" "$CORE_DIR"
fi
echo "==> core: $CORE_DIR ($(git -C "$CORE_DIR" rev-parse --short HEAD))"
cd "$CORE_DIR"

npm ci
# --legacy-peer-deps: the aws-blockchain-node-runners peer is not on the npm registry.
# --install-links: copy the package in, as a GitHub/npm install would, instead of symlinking.
# Saved to the root package.json on purpose: ConfigurationLoader only scans listed dependencies.
npm install "$BLUEPRINT_DIR" --legacy-peer-deps --install-links

echo "==> integration tests"
mkdir -p test/integration
for t in "$BLUEPRINT_DIR"/test/*.test.ts; do
  cp "$t" "test/integration/community-$(basename "$t")"
done
npx jest test/integration/community-

echo "==> credential-free cdk synth of every sample"
cat > cdk.context.json <<'EOF'
{
  "vpc-provider:account=123456789012:filter.isDefault=true:region=us-east-1:returnAsymmetricSubnets=true": {
    "vpcId": "vpc-00000000000000000",
    "vpcCidrBlock": "10.0.0.0/16",
    "ownerAccountId": "123456789012",
    "availabilityZones": [],
    "subnetGroups": [
      {
        "name": "Public",
        "type": "Public",
        "subnets": [
          { "subnetId": "subnet-00000000000000001", "cidr": "10.0.0.0/20", "availabilityZone": "us-east-1a", "routeTableId": "rtb-00000000000000001" },
          { "subnetId": "subnet-00000000000000002", "cidr": "10.0.16.0/20", "availabilityZone": "us-east-1b", "routeTableId": "rtb-00000000000000001" }
        ]
      }
    ]
  },
  "availability-zones:account=123456789012:region=us-east-1": ["us-east-1a", "us-east-1b"]
}
EOF

for sample in node_modules/"$PKG"/samples/.env-*; do
  echo "--> $(basename "$sample")"
  sed -e 's/^AWS_ACCOUNT_ID=.*/AWS_ACCOUNT_ID="123456789012"/' \
      -e 's/^AWS_REGION=.*/AWS_REGION="us-east-1"/' "$sample" > .env
  BLOCKCHAIN_PROTOCOL="$PROTOCOL" npx cdk synth --quiet > /dev/null
done

echo "==> ${PKG}: all checks passed"
