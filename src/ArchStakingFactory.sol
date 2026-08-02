// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStakingPool} from "./ArchStakingPool.sol";

/// @title ArchStakingFactory
/// @notice Deploys staking pools for a flat fee. Each pool skims a fixed
///         protocol share of the rewards its operator funds. Holds no user
///         funds; the flat fee is forwarded to the treasury.
contract ArchStakingFactory is ReentrancyGuard {
    uint256 public immutable FEE; // flat pool-deploy fee
    address payable public immutable TREASURY;
    uint16 public immutable REWARD_FEE_BPS; // protocol share of rewards (e.g. 200 = 2%)

    address[] public pools;

    event PoolCreated(address indexed pool, address indexed creator, address stakingToken, address rewardsToken);

    constructor(uint256 fee, address payable treasury, uint16 rewardFeeBps) {
        require(treasury != address(0), "stakefactory: zero treasury");
        require(rewardFeeBps <= 1000, "stakefactory: fee too high");
        FEE = fee;
        TREASURY = treasury;
        REWARD_FEE_BPS = rewardFeeBps;
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function createPool(IERC20 stakingToken, IERC20 rewardsToken, uint256 rewardsDuration, uint64 lockDuration)
        external
        payable
        nonReentrant
        returns (address poolAddr)
    {
        require(msg.value == FEE, "stakefactory: wrong fee");

        ArchStakingPool pool = new ArchStakingPool(
            msg.sender, stakingToken, rewardsToken, TREASURY, REWARD_FEE_BPS, rewardsDuration, lockDuration
        );
        poolAddr = address(pool);
        pools.push(poolAddr);

        (bool ok,) = TREASURY.call{value: msg.value}("");
        require(ok, "stakefactory: fee send failed");

        emit PoolCreated(poolAddr, msg.sender, address(stakingToken), address(rewardsToken));
    }
}
