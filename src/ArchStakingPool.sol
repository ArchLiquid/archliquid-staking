// SPDX-License-Identifier: LicenseRef-ArchLiquid-Proprietary
pragma solidity 0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ArchStakingPool
/// @notice Staking rewards pool using a reward-per-token accumulator (native
///         checked math). Each funded reward is skimmed by a 2% protocol fee to
///         the treasury; the remainder streams linearly over the reward
///         duration. Stakes may carry an optional withdraw lock, and staking
///         uses received-amount accounting for fee-on-transfer safety.
contract ArchStakingPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKING_TOKEN;
    IERC20 public immutable REWARDS_TOKEN;
    address payable public immutable TREASURY;
    uint16 public immutable REWARD_FEE_BPS; // skimmed from each funded reward
    uint64 public immutable LOCK_DURATION; // per-stake withdraw lock (0 = none)

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public unlockAt;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 fee);
    event Recovered(address indexed token, uint256 amount);

    constructor(
        address owner_,
        IERC20 stakingToken,
        IERC20 rewardsToken,
        address payable treasury,
        uint16 rewardFeeBps,
        uint256 rewardsDuration_,
        uint64 lockDuration
    ) Ownable(owner_) {
        require(address(stakingToken) != address(0) && address(rewardsToken) != address(0), "pool: zero token");
        require(treasury != address(0), "pool: zero treasury");
        require(rewardsDuration_ > 0, "pool: zero duration");
        require(rewardFeeBps <= 1000, "pool: fee too high");
        STAKING_TOKEN = stakingToken;
        REWARDS_TOKEN = rewardsToken;
        TREASURY = treasury;
        REWARD_FEE_BPS = rewardFeeBps;
        rewardsDuration = rewardsDuration_;
        LOCK_DURATION = lockDuration;
    }

    /* ── views ───────────────────────────────────────────────────── */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    /* ── stake / withdraw / claim ────────────────────────────────── */

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "pool: zero stake");
        // received-amount accounting for fee-on-transfer staking tokens
        uint256 before = STAKING_TOKEN.balanceOf(address(this));
        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = STAKING_TOKEN.balanceOf(address(this)) - before;
        require(received > 0, "pool: nothing received");

        _totalSupply += received;
        _balances[msg.sender] += received;
        if (LOCK_DURATION > 0) unlockAt[msg.sender] = block.timestamp + LOCK_DURATION;
        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "pool: zero withdraw");
        require(block.timestamp >= unlockAt[msg.sender], "pool: locked");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        STAKING_TOKEN.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            REWARDS_TOKEN.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ── fund rewards (owner) ────────────────────────────────────── */

    /// @notice Fund a reward period. Pulls `reward` from the caller, skims the
    ///         protocol fee to the treasury, and streams the rest over
    ///         `rewardsDuration`. Solvency is enforced against the actual
    ///         reward balance.
    function notifyRewardAmount(uint256 reward) external onlyOwner nonReentrant updateReward(address(0)) {
        require(reward > 0, "pool: zero reward");
        uint256 balanceBefore = REWARDS_TOKEN.balanceOf(address(this));
        REWARDS_TOKEN.safeTransferFrom(msg.sender, address(this), reward);
        uint256 balanceAfterPull = REWARDS_TOKEN.balanceOf(address(this));
        uint256 received = balanceAfterPull - balanceBefore;
        require(received > 0, "pool: no rewards received");

        uint256 fee = (received * REWARD_FEE_BPS) / 10_000;
        if (fee > 0) REWARDS_TOKEN.safeTransfer(TREASURY, fee);
        // Measure what remains rather than assuming transfer behavior. This
        // keeps the schedule backed when the reward token charges transfer fees.
        uint256 net = REWARDS_TOKEN.balanceOf(address(this)) - balanceBefore;

        if (block.timestamp >= periodFinish) {
            rewardRate = net / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (net + leftover) / rewardsDuration;
        }

        // never let rewardRate outrun the actual reward balance
        uint256 balance = REWARDS_TOKEN.balanceOf(address(this));
        if (address(REWARDS_TOKEN) == address(STAKING_TOKEN)) {
            // Staked principal cannot be counted as backing for rewards.
            require(balance >= _totalSupply, "pool: stake balance shortfall");
            balance -= _totalSupply;
        }
        require(rewardRate <= balance / rewardsDuration, "pool: reward exceeds balance");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(net, fee);
    }

    /// @notice Recover tokens accidentally sent in. Neither the staking token
    ///         nor the rewards token can ever be recovered: stakes are safe
    ///         from the owner, and once funded, rewards are committed to
    ///         stakers and cannot be pulled back. Only stray third tokens are
    ///         recoverable.
    function recoverERC20(IERC20 token, uint256 amount) external onlyOwner nonReentrant {
        require(address(token) != address(STAKING_TOKEN), "pool: cannot recover stake");
        require(address(token) != address(REWARDS_TOKEN), "pool: cannot recover rewards");
        token.safeTransfer(owner(), amount);
        emit Recovered(address(token), amount);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
}
