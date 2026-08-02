// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStakingFactory} from "../src/ArchStakingFactory.sol";
import {ArchStakingPool} from "../src/ArchStakingPool.sol";
import {MockERC20} from "./mocks/Mocks.sol";

contract ArchStakingTest is Test {
    uint256 constant DEPLOY_FEE = 0.05 ether;
    uint16 constant REWARD_FEE_BPS = 200; // 2%
    uint256 constant DURATION = 30 days;

    address payable treasury;
    ArchStakingFactory factory;
    MockERC20 stakeTok;
    MockERC20 rewardTok;
    ArchStakingPool pool;

    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        treasury = payable(makeAddr("treasury"));
        factory = new ArchStakingFactory(DEPLOY_FEE, treasury, REWARD_FEE_BPS);
        stakeTok = new MockERC20("Stake", "STK");
        rewardTok = new MockERC20("Reward", "RWD");

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        address p =
            factory.createPool{value: DEPLOY_FEE}(IERC20(address(stakeTok)), IERC20(address(rewardTok)), DURATION, 0);
        pool = ArchStakingPool(p);

        stakeTok.mint(alice, 1000e18);
        stakeTok.mint(bob, 1000e18);
        rewardTok.mint(operator, 1_000_000e18);

        vm.prank(alice);
        stakeTok.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        stakeTok.approve(address(pool), type(uint256).max);
        vm.prank(operator);
        rewardTok.approve(address(pool), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        vm.prank(operator);
        pool.notifyRewardAmount(amount);
    }

    function test_create_takesFee() public {
        assertEq(treasury.balance, DEPLOY_FEE);
        assertEq(factory.poolCount(), 1);
        assertEq(pool.owner(), operator);
    }

    function test_notify_skimsProtocolFee() public {
        _fund(30_000e18);
        // 2% of the reward goes to the treasury immediately
        assertEq(rewardTok.balanceOf(treasury), 600e18);
        // the rest funds the pool
        assertEq(rewardTok.balanceOf(address(pool)), 29_400e18);
    }

    function test_singleStaker_earnsNetRewards() public {
        vm.prank(alice);
        pool.stake(100e18);
        _fund(30_000e18); // net 29,400 over 30 days

        vm.warp(block.timestamp + DURATION);
        uint256 earned = pool.earned(alice);
        // sole staker earns ~all net rewards (minus dust from rate flooring)
        assertApproxEqRel(earned, 29_400e18, 1e15); // within 0.1%

        vm.prank(alice);
        pool.getReward();
        assertApproxEqRel(rewardTok.balanceOf(alice), 29_400e18, 1e15);
    }

    function test_twoStakers_splitProRata() public {
        vm.prank(alice);
        pool.stake(100e18);
        vm.prank(bob);
        pool.stake(300e18); // bob has 3x
        _fund(40_000e18);

        vm.warp(block.timestamp + DURATION);
        uint256 a = pool.earned(alice);
        uint256 b = pool.earned(bob);
        // bob earns ~3x alice
        assertApproxEqRel(b, a * 3, 1e15);
    }

    function test_withdrawAndExit() public {
        vm.prank(alice);
        pool.stake(100e18);
        _fund(30_000e18);
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        pool.exit();
        assertEq(stakeTok.balanceOf(alice), 1000e18); // full stake back
        assertGt(rewardTok.balanceOf(alice), 0); // plus rewards
        assertEq(pool.balanceOf(alice), 0);
    }

    function test_lockPreventsEarlyWithdraw() public {
        vm.prank(operator);
        address p = factory.createPool{value: DEPLOY_FEE}(
            IERC20(address(stakeTok)), IERC20(address(rewardTok)), DURATION, 7 days
        );
        vm.deal(operator, 1 ether);
        ArchStakingPool locked = ArchStakingPool(p);
        vm.startPrank(alice);
        stakeTok.approve(address(locked), type(uint256).max);
        locked.stake(100e18);
        vm.expectRevert("pool: locked");
        locked.withdraw(100e18);
        vm.warp(block.timestamp + 7 days);
        locked.withdraw(100e18);
        vm.stopPrank();
        assertEq(stakeTok.balanceOf(alice), 1000e18);
    }

    function test_notify_onlyOwner() public {
        vm.prank(alice);
        rewardTok.mint(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert();
        pool.notifyRewardAmount(1000e18);
    }

    function test_recover_cannotTakeStake() public {
        vm.prank(alice);
        pool.stake(100e18);
        vm.prank(operator);
        vm.expectRevert("pool: cannot recover stake");
        pool.recoverERC20(IERC20(address(stakeTok)), 100e18);
    }

    function test_recover_cannotTakeRewards() public {
        _fund(30_000e18);
        // funded rewards are committed to stakers; the owner cannot claw them back
        vm.prank(operator);
        vm.expectRevert("pool: cannot recover rewards");
        pool.recoverERC20(IERC20(address(rewardTok)), 1e18);
    }

    function test_solvency_rewardRateBounded() public {
        // notifying more than transferred is impossible: notify pulls the
        // reward in first, so the balance check always holds. Fund twice and
        // confirm accounting stays solvent.
        vm.prank(alice);
        pool.stake(100e18);
        _fund(30_000e18);
        vm.warp(block.timestamp + 10 days);
        _fund(15_000e18); // top up mid-period
        vm.warp(block.timestamp + DURATION);

        uint256 earned = pool.earned(alice);
        // never earn more than the net funded (44,100)
        assertLe(earned, 44_100e18);
        vm.prank(alice);
        pool.getReward();
        assertLe(rewardTok.balanceOf(alice), 44_100e18);
    }
}
