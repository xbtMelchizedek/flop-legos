// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Unaudited. TESTNET ONLY. Shared shape for deploy and smoke: chain guard, key read, deployments/<chainid>.json.

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

abstract contract FlopVaultDeployment is Script {
    error WrongChain(uint256 chainId);
    error DeploymentExists(string path);

    struct Deployment {
        address deployer;
        address tUSDC;
        address tFLOP;
        address strategy;
        address vault;
        address primaryFeed;
        address secondaryFeed;
        address oracle;
        address market;
        address miner;
    }

    /// Robinhood Chain testnet. Source: docs/ROBINHOOD_CHAIN.md. Every other chain is refused, mainnet included.
    uint256 public constant RHC_TESTNET_CHAIN_ID = 46630;

    function _requireTestnet() internal view {
        if (block.chainid != RHC_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);
    }

    /// Set only by scripts/rhc.sh from the mode-600 file named by DEPLOYER_KEY_FILE. Never logged.
    function _deployerKey() internal view returns (uint256) {
        return vm.envUint("DEPLOYER_KEY");
    }

    function _deploymentDir() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", vm.envOr("DEPLOYMENTS_DIR", string("deployments")));
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat(_deploymentDir(), "/", vm.toString(block.chainid), ".json");
    }

    /// Dry runs write nothing, and a broadcast never overwrites an earlier record (move it aside first).
    function _write(Deployment memory d) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        string memory path = _deploymentPath();
        if (vm.exists(path)) revert DeploymentExists(path);
        vm.createDir(_deploymentDir(), true);
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "note", "FlopVault unaudited prototype. TEST mocks only, no value, testnet only.");
        vm.serializeAddress(k, "deployer", d.deployer);
        vm.serializeAddress(k, "tUSDC", d.tUSDC);
        vm.serializeAddress(k, "tFLOP", d.tFLOP);
        vm.serializeAddress(k, "strategy", d.strategy);
        vm.serializeAddress(k, "vault", d.vault);
        vm.serializeAddress(k, "primaryFeed", d.primaryFeed);
        vm.serializeAddress(k, "secondaryFeed", d.secondaryFeed);
        vm.serializeAddress(k, "oracle", d.oracle);
        vm.serializeAddress(k, "market", d.market);
        string memory json = vm.serializeAddress(k, "miner", d.miner);
        vm.writeJson(json, path);
    }

    function _read() internal view returns (Deployment memory d) {
        string memory json = vm.readFile(_deploymentPath());
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert WrongChain(block.chainid);
        d.deployer = vm.parseJsonAddress(json, ".deployer");
        d.tUSDC = vm.parseJsonAddress(json, ".tUSDC");
        d.tFLOP = vm.parseJsonAddress(json, ".tFLOP");
        d.strategy = vm.parseJsonAddress(json, ".strategy");
        d.vault = vm.parseJsonAddress(json, ".vault");
        d.primaryFeed = vm.parseJsonAddress(json, ".primaryFeed");
        d.secondaryFeed = vm.parseJsonAddress(json, ".secondaryFeed");
        d.oracle = vm.parseJsonAddress(json, ".oracle");
        d.market = vm.parseJsonAddress(json, ".market");
        d.miner = vm.parseJsonAddress(json, ".miner");
    }
}
