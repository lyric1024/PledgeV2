// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PledgePool} from "../src/PledgePool.sol";
import {DebtToken} from "../src/DebtToken.sol";
import {MultiSignature} from "../src/MultiSignature.sol";
import {BscPledgeOracle} from "../src/BscPledgeOracle.sol";
import {AddressPrivileges} from "../src/AddressPrivileges.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title PledgePool Deployment Script
 * @notice Deploys the complete PledgePool ecosystem including:
 *         - AddressPrivileges
 *         - DebtToken contracts (SPT and JPT)
 *         - MultiSignature contract
 *         - BscPledgeOracle contract
 *         - PledgePool main contract
 */
contract PledgePoolScript is Script {
    // ==================== Deployment Variables ====================

    // Multi-signature configuration
    address[] admins;
    uint256 requiredVotes = 2; // 2/3 multi-sig requirement

    // Deployed contracts
    AddressPrivileges public privileges;
    DebtToken public spToken; // Lend share token
    DebtToken public jpToken; // Borrow share token
    MultiSignature public multiSig;
    BscPledgeOracle public oracle;
    PledgePool public pledgePool;

    // Configuration
    address feeCollector; // Platform fee receiver

    function setUp() public {
        // Setup admins - modify these addresses as needed
        admins = new address[](3);
        admins[0] = 0x1111111111111111111111111111111111111111;
        admins[1] = 0x2222222222222222222222222222222222222222;
        admins[2] = 0x3333333333333333333333333333333333333333;

        // Setup fee collector
        feeCollector = 0x4444444444444444444444444444444444444444;
    }

    function run() public {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===== PledgePool Deployment =====");
        console.log("Deployer:", deployer);
        console.log("Number of Admins:", admins.length);
        console.log("Required Votes:", requiredVotes);
        console.log("Fee Collector:", feeCollector);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AddressPrivileges
        console.log("1. Deploying AddressPrivileges...");
        privileges = new AddressPrivileges(deployer);
        console.log("   AddressPrivileges deployed at:", address(privileges));
        console.log("");

        // 2. Deploy DebtTokens (SPT and JPT)
        console.log("2. Deploying DebtTokens...");
        spToken = new DebtToken("Lend Share Token", "SPT", privileges);
        console.log("   SPT (Lend Share Token) deployed at:", address(spToken));

        jpToken = new DebtToken("Borrow Share Token", "JPT", privileges);
        console.log(
            "   JPT (Borrow Share Token) deployed at:",
            address(jpToken)
        );
        console.log("");

        // 3. Deploy MultiSignature
        console.log("3. Deploying MultiSignature...");
        console.log("   Admin 1:", admins[0]);
        console.log("   Admin 2:", admins[1]);
        console.log("   Admin 3:", admins[2]);
        multiSig = new MultiSignature(admins, requiredVotes);
        console.log("   MultiSignature deployed at:", address(multiSig));
        console.log("");

        // 4. Deploy BscPledgeOracle
        console.log("4. Deploying BscPledgeOracle...");
        oracle = new BscPledgeOracle();
        console.log("   BscPledgeOracle deployed at:", address(oracle));
        console.log("");

        // 5. Deploy PledgePool
        console.log("5. Deploying PledgePool...");
        pledgePool = new PledgePool(
            address(oracle),
            address(multiSig),
            feeCollector
        );
        console.log("   PledgePool deployed at:", address(pledgePool));
        console.log("");

        // 6. Setup privileges for minting
        console.log("6. Setting up privileges...");
        privileges.addMinter(address(pledgePool));
        console.log("   PledgePool minter privilege granted");
        console.log("");

        vm.stopBroadcast();

        // ==================== Deployment Summary ====================
        console.log("===== Deployment Complete =====");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("- AddressPrivileges:", address(privileges));
        console.log("- SPT (Lend Share Token):", address(spToken));
        console.log("- JPT (Borrow Share Token):", address(jpToken));
        console.log("- MultiSignature:", address(multiSig));
        console.log("- BscPledgeOracle:", address(oracle));
        console.log("- PledgePool:", address(pledgePool));
        console.log("");
        console.log("Configuration:");
        console.log("- Deployer:", deployer);
        console.log("- Fee Collector:", feeCollector);
        console.log("- Multi-sig Requirement: 2/3");
        console.log("");
    }
}
