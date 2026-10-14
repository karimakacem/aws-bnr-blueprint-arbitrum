// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Runs inside an aws-blockchain-node-runners checkout with this blueprint
// installed (see .github/workflows/ci.yml): copy this file to test/integration/.

import * as fs from 'fs';
import * as path from 'path';
import { ConfigurationLoader } from '../../lib/core/configuration-loader';
import { DeploymentMode } from '../../lib/interfaces/enums';

const BLUEPRINT = path.join(process.cwd(), 'node_modules', 'aws-bnr-blueprint-arbitrum');
const CONFIG = 'nitro-v3.12.1-full.yml';
// minDataGiB: a snapshot restore holds the downloaded archive and the extracted
// database at once (~2x the pruned snapshot), so each network's volume must
// cover that peak.
const SAMPLES: Array<{ file: string; network: string; mode: DeploymentMode; minDataGiB: number; l1: 'mainnet' | 'sepolia' }> = [
    { file: '.env-mainnet-nitro-full', network: 'mainnet', mode: DeploymentMode.SINGLE_NODE, minDataGiB: 5000, l1: 'mainnet' },
    { file: '.env-mainnet-nitro-full-ha', network: 'mainnet', mode: DeploymentMode.HA_NODES, minDataGiB: 5000, l1: 'mainnet' },
    // Nova settles to Ethereum mainnet too.
    { file: '.env-nova-nitro-full', network: 'nova', mode: DeploymentMode.SINGLE_NODE, minDataGiB: 1200, l1: 'mainnet' },
    { file: '.env-testnet-nitro-full', network: 'testnet', mode: DeploymentMode.SINGLE_NODE, minDataGiB: 4000, l1: 'sepolia' },
];

describe('Arbitrum Protocol Configuration', () => {
    let configLoader: ConfigurationLoader;

    beforeEach(() => {
        configLoader = new ConfigurationLoader('blueprints');
    });

    describe('Protocol Configuration', () => {
        it('should load the Arbitrum protocol configuration', () => {
            const protocolConfig = configLoader.loadProtocolConfig('arbitrum');

            expect(protocolConfig.BLOCKCHAIN_PROTOCOL).toBe('arbitrum');
            expect(protocolConfig.supportedDeploymentModes).toContain(DeploymentMode.SINGLE_NODE);
            expect(protocolConfig.supportedDeploymentModes).toContain(DeploymentMode.HA_NODES);
            expect(protocolConfig.BC_NETWORKS).toEqual(['mainnet', 'nova', 'testnet']);
        });

        it('should default to the pinned client configuration', () => {
            const protocolConfig = configLoader.loadProtocolConfig('arbitrum');

            expect(protocolConfig.defaultConfiguration).toBe(CONFIG);
            expect(protocolConfig.availableConfigurations.map(c => c.name)).toContain(CONFIG);
        });

        it('should expose only VPC-internal RPC, WebSocket and metrics ports', () => {
            const protocolConfig = configLoader.loadProtocolConfig('arbitrum');

            expect(protocolConfig.requiredPorts.map(p => p.port).sort()).toEqual([6070, 8547, 8548]);
            protocolConfig.requiredPorts.forEach(p => {
                expect(p.protocol).toBe('tcp');
                expect(p.public).toBe(false);
            });
        });

        it('should declare the L1 endpoints as ARBITRUM custom variables', () => {
            const protocolConfig = configLoader.loadProtocolConfig('arbitrum');

            expect(protocolConfig.customEnvVarsNamePrefix).toBe('ARBITRUM');
            const names = (protocolConfig.customEnvVars ?? []).map(v => v.split('=')[0]);
            expect(names).toContain('ARBITRUM_L1_RPC_URL');
            expect(names).toContain('ARBITRUM_L1_BEACON_URL');
        });
    });

    describe.each(SAMPLES)('Sample $file', ({ file, network, mode, minDataGiB, l1 }) => {
        const envPath = path.join(BLUEPRINT, 'samples', file);

        it('should load with the expected network, mode and client configuration', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);

            expect(envConfig.BLOCKCHAIN_PROTOCOL).toBe('arbitrum');
            expect(envConfig.BC_NETWORK).toBe(network);
            expect(envConfig.DEPLOYMENT_MODE).toBe(mode);
            expect(envConfig.CLIENT_CONFIG).toBe(CONFIG);
        });

        it('should pass configuration validation apart from the account ID placeholder', () => {
            // Samples ship the repo-wide AWS_ACCOUNT_ID placeholder; users set
            // their own. Every other validation rule must pass. (The stand-in ID
            // is built at runtime so git-secrets does not flag a literal.)
            const envConfig = configLoader.loadEnvironmentConfig(envPath);
            const result = configLoader.validateConfiguration({ ...envConfig, AWS_ACCOUNT_ID: '1'.repeat(12) });

            expect(result.errors).toEqual([]);
            expect(result.isValid).toBe(true);
        });

        it('should set real L1 endpoints for its parent chain', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);
            const rpc = envConfig.CUSTOM_VARIABLES.ARBITRUM_L1_RPC_URL;
            const beacon = envConfig.CUSTOM_VARIABLES.ARBITRUM_L1_BEACON_URL;

            expect(rpc).toMatch(/^https:\/\//);
            expect(beacon).toMatch(/^https:\/\//);
            expect(rpc).not.toContain('your-');
            expect(beacon).not.toContain('your-');
            // publicnode's free execution RPC refuses the historical eth_getLogs
            // Nitro needs after a snapshot restore.
            expect(rpc).not.toContain('publicnode');
            if (l1 === 'sepolia') {
                expect(rpc).toContain('sepolia');
                expect(beacon).toContain('sepolia');
            } else {
                expect(rpc).not.toContain('sepolia');
                expect(beacon).not.toContain('sepolia');
            }
        });

        it('should size the data volume for the snapshot restore', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);
            const dataVol = envConfig.DATA_VOLUMES.find(v => v.MOUNT_PATH === '/data');

            expect(dataVol).toBeDefined();
            expect(dataVol!.SIZE).toBeGreaterThanOrEqual(minDataGiB);
        });

        it('should leave the framework S3 snapshot restore disabled', () => {
            const envConfig = configLoader.loadEnvironmentConfig(envPath);

            expect(envConfig.SNAPSHOT_ENABLED).toBe(false);
        });
    });

    describe('HA sample', () => {
        it('should accept the HTTP 400 Nitro returns for a plain GET on the RPC port', () => {
            const envPath = path.join(BLUEPRINT, 'samples', '.env-mainnet-nitro-full-ha');
            const envConfig = configLoader.loadEnvironmentConfig(envPath);

            expect(configLoader.validateHAConfigVariables(envConfig).isValid).toBe(true);
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_PORT).toBe(8547);
            expect(envConfig.HA_CONFIG!.HA_ALB_HEALTHCHECK_HTTP_CODES.split(',')).toContain('400');
        });
    });

    describe('Blueprint files', () => {
        it('should ship the required files', () => {
            ['package.json', 'README.md', 'user-data/node.sh'].forEach(f => {
                expect(fs.existsSync(path.join(BLUEPRINT, f))).toBe(true);
            });
        });

        it('should have a file for every available configuration', () => {
            const protocolConfig = configLoader.loadProtocolConfig('arbitrum');

            protocolConfig.availableConfigurations.forEach(config => {
                expect(fs.existsSync(path.join(BLUEPRINT, 'configurations', config.name))).toBe(true);
            });
        });

        it('should pin the Nitro image to the configuration version with an immutable tag', () => {
            const version = CONFIG.match(/^nitro-(v\d+\.\d+\.\d+)-full\.yml$/)![1];
            const marker = fs.readFileSync(path.join(BLUEPRINT, 'configurations', CONFIG), 'utf8');

            expect(marker).toMatch(new RegExp(`^nitro_image: "offchainlabs/nitro-node:${version.replace(/\./g, '\\.')}-[0-9a-f]{7}"$`, 'm'));
            expect(marker).not.toMatch(/nitro-node:latest\b/);
        });
    });
});
