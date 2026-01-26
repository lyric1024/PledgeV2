// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {PledgePool} from "../src/PledgePool.sol";
import {DebtToken} from "../src/DebtToken.sol";
import {MultiSignature} from "../src/MultiSignature.sol";
import {BscPledgeOracle} from "../src/BscPledgeOracle.sol";
import {AddressPrivileges} from "../src/AddressPrivileges.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PledgePoolTest is Test {
    PledgePool public pledgePool;
    DebtToken public spToken;
    DebtToken public jpToken;
    MultiSignature public multiSig;
    BscPledgeOracle public oracle;
    AddressPrivileges public privileges;

    // Mock ERC20 tokens
    ERC20Mock public lendToken;
    ERC20Mock public borrowToken;

    // Test addresses
    address public admin1 = address(0x1);
    address public admin2 = address(0x2);
    address public admin3 = address(0x3);
    address public lender = address(0x4);
    address public borrower = address(0x5);
    address public feeCollector = address(0x6);

    // Test parameters
    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant MIN_DEPOSIT = 1e16; // 0.01
    uint256 public constant BASE_DECIMAL = 1e18;

    function setUp() public {
        // Create mock tokens
        lendToken = new ERC20Mock();
        borrowToken = new ERC20Mock();

        // Create AddressPrivileges
        privileges = new AddressPrivileges(admin1);

        // Create DebtTokens
        spToken = new DebtToken("Lend Share Token", "SPT", privileges);
        jpToken = new DebtToken("Borrow Share Token", "JPT", privileges);

        // Create MultiSignature with 2/3 requirement
        address[] memory admins = new address[](3);
        admins[0] = admin1;
        admins[1] = admin2;
        admins[2] = admin3;
        multiSig = new MultiSignature(admins, 2);

        // Create mock Oracle
        oracle = new BscPledgeOracle();

        // Create PledgePool
        pledgePool = new PledgePool(
            address(oracle),
            address(multiSig),
            feeCollector
        );

        // Set privileges for minting
        vm.prank(admin1);
        privileges.addMinter(address(pledgePool));

        // Distribute initial balances
        lendToken.mint(lender, INITIAL_BALANCE);
        borrowToken.mint(borrower, INITIAL_BALANCE);

        // Approve tokens for PledgePool
        vm.prank(lender);
        lendToken.approve(address(pledgePool), type(uint256).max);

        vm.prank(borrower);
        borrowToken.approve(address(pledgePool), type(uint256).max);
    }

    // ==================== Pool Creation Tests ====================

    function testCreatePool() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        uint256 interestRate = 5e16; // 5% per year
        uint256 maxSupply = 100e18;
        uint256 mortgageRate = 2e18; // 2x
        uint256 autoLiquidateThreshold = 1e17; // 10%

        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            interestRate,
            maxSupply,
            mortgageRate,
            autoLiquidateThreshold,
            address(spToken),
            address(jpToken)
        );

        assertNotEq(poolId, 0, "Pool ID should not be zero");
    }

    function testCreatePoolWithInvalidTokens() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;

        vm.prank(admin1);
        vm.expectRevert("PledgePool: invilid tokens");
        pledgePool.createPool(
            address(0),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );
    }

    function testCreatePoolWithInvalidSettleTime() public {
        uint256 settleTime = block.timestamp - 1 days; // Past time
        uint256 endTime = block.timestamp + 30 days;

        vm.prank(admin1);
        vm.expectRevert("PledgePool: invalid settle time");
        pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );
    }

    function testCreatePoolWithInvalidEndTime() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = settleTime - 1; // endTime before settleTime

        vm.prank(admin1);
        vm.expectRevert("PledgePool: invalid endTime");
        pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );
    }

    // ==================== Lender Tests ====================

    function testDepositLend() public {
        // Create pool first
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        // Deposit as lender
        uint256 depositAmount = 50e18;
        vm.prank(lender);
        pledgePool.depositLend(poolId, depositAmount);

        // Verify deposit
        (uint256 stakeAmount, , ) = pledgePool.lendInfos(poolId, lender);
        assertEq(stakeAmount, depositAmount, "Lender stake amount mismatch");
    }

    function testDepositLendTooSmall() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        vm.prank(lender);
        vm.expectRevert("PledgePool: amount too small");
        pledgePool.depositLend(poolId, 1e15); // Less than MIN_DEPOSIT
    }

    function testDepositLendExceedsMaxSupply() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        uint256 maxSupply = 50e18;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            maxSupply,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        vm.prank(lender);
        vm.expectRevert("PledgePool: exceed maxSupply");
        pledgePool.depositLend(poolId, maxSupply + 1e18);
    }

    function testDepositLendAfterSettleTime() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        // Fast forward past settle time
        vm.warp(settleTime + 1);

        vm.prank(lender);
        vm.expectRevert("PledgePool: after settleTime");
        pledgePool.depositLend(poolId, 50e18);
    }

    // ==================== Borrower Tests ====================

    function testDepositBorrow() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        uint256 depositAmount = 30e18;
        vm.prank(borrower);
        pledgePool.depositBorrow(poolId, depositAmount);

        // Verify deposit
        (uint256 stakeAmount, , , , ) = pledgePool.borrowInfos(
            poolId,
            borrower
        );
        assertEq(stakeAmount, depositAmount, "Borrower stake amount mismatch");
    }

    function testDepositBorrowTooSmall() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        vm.prank(borrower);
        vm.expectRevert("PledgePool: amount too small");
        pledgePool.depositBorrow(poolId, 1e15);
    }

    // ==================== Multiple Deposits Tests ====================

    function testMultipleDeposits() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            1000e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        // Multiple deposits by same user
        vm.prank(lender);
        pledgePool.depositLend(poolId, 25e18);
        pledgePool.depositLend(poolId, 25e18);

        (uint256 totalStake, , ) = pledgePool.lendInfos(poolId, lender);
        assertEq(totalStake, 50e18, "Multiple deposits should accumulate");
    }

    function testMinimumDepositBoundary() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18,
            1e17,
            address(spToken),
            address(jpToken)
        );

        // Exactly at minimum deposit
        vm.prank(lender);
        pledgePool.depositLend(poolId, MIN_DEPOSIT);

        (uint256 stakeAmount, , ) = pledgePool.lendInfos(poolId, lender);
        assertEq(
            stakeAmount,
            MIN_DEPOSIT,
            "Should accept minimum deposit amount"
        );
    }

    // ==================== Helper Tests ====================

    function testCalculateMaxBorrowable() public {
        uint256 settleTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 30 days;
        vm.prank(admin1);
        uint256 poolId = pledgePool.createPool(
            address(lendToken),
            address(borrowToken),
            settleTime,
            endTime,
            5e16,
            100e18,
            2e18, // 2x mortgage rate
            1e17,
            address(spToken),
            address(jpToken)
        );

        // Note: This test requires oracle price setup
        // For now, we just verify the function exists
        uint256 maxBorrowable = pledgePool.calculateMaxBorrowable(
            poolId,
            borrower
        );
        assertEq(maxBorrowable, 0, "Should be 0 with no collateral");
    }
}
