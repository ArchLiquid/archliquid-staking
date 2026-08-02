# ArchLiquid Staking

Factory-created ERC-20 staking pools with funded linear rewards and optional
withdrawal locks.

> **Status:** Testnet preview. These contracts have not been audited by an
> external security firm. Review the source and run the test suite before
> interacting with a deployment.

## What is included

| Contract | Purpose |
|---|---|
| [`ArchStakingFactory`](src/ArchStakingFactory.sol) | Creates pools, forwards an immutable flat fee, and records every pool address. |
| [`ArchStakingPool`](src/ArchStakingPool.sol) | Accounts for stakes with a reward-per-token accumulator and streams funded rewards over time. |

Each pool has an immutable staking token, rewards token, treasury, protocol
reward fee, and per-stake lock duration. The pool creator becomes its
OpenZeppelin `Ownable2Step` owner and is responsible for funding reward periods.

## Reward flow

```text
pool owner funds rewards
          │
          ├── immutable protocol percentage ──> treasury
          │
          └── measured net balance
                    │ streamed over rewardsDuration
                    v
              reward-per-token accumulator
                    │
                    v
                 stakers
```

The pool never creates rewards from accounting alone. `notifyRewardAmount`
pulls tokens first and bounds `rewardRate` against the actual balance available
for rewards.

## Install and build

```bash
git clone --recurse-submodules https://github.com/ArchLiquid/archliquid-staking.git
cd archliquid-staking
forge build
forge test
forge build --sizes
```

Compiler settings are fixed in [`foundry.toml`](foundry.toml): Solidity 0.8.30,
Paris EVM, optimizer enabled with 200 runs, and IR compilation.

## Create a pool

The creation transaction sends exactly the factory's immutable fee. The reward
fee is configured on the factory and can be at most 10% (`1000` basis points).

```solidity
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArchStakingFactory} from
    "@archliquid/staking/ArchStakingFactory.sol";
import {ArchStakingPool} from
    "@archliquid/staking/ArchStakingPool.sol";

address poolAddress = factory.createPool{value: factory.FEE()}(
    IERC20(stakingToken),
    IERC20(rewardsToken),
    30 days,
    uint64(7 days)
);

ArchStakingPool pool = ArchStakingPool(poolAddress);
```

`rewardsDuration` must be nonzero. Set `lockDuration` to zero for freely
withdrawable stakes.

## Fund a reward period

Only the pool owner can fund rewards.

```solidity
IERC20(rewardsToken).approve(address(pool), rewardAmount);
pool.notifyRewardAmount(rewardAmount);
```

The pool measures how many tokens it actually receives, forwards the configured
percentage to the treasury, and streams the remaining measured balance over
`rewardsDuration`. Funding before the current period ends carries its scheduled
leftover into the new rate.

If the staking and reward token are the same asset, staked principal is removed
from the balance available to back rewards.

## Stake, inspect, and exit

```solidity
IERC20(stakingToken).approve(address(pool), stakeAmount);
pool.stake(stakeAmount);

uint256 deposited = pool.balanceOf(address(this));
uint256 pending = pool.earned(address(this));

pool.getReward();
pool.withdraw(deposited);
```

`exit()` combines a full withdrawal and reward claim. When a lock duration is
configured, each successful stake sets that account's `unlockAt` to the current
timestamp plus the full duration. Adding a stake therefore restarts the lock
for the account's complete pool balance.

Stake accounting uses the amount actually received, which supports
fee-on-transfer staking tokens without overstating principal. Applications
should still review reward-token transfer behavior because transfer fees can
affect the amount a user ultimately receives.

## Owner permissions

The pool owner can:

- fund or extend reward periods with `notifyRewardAmount`;
- start a two-step ownership transfer; and
- recover an unrelated token accidentally sent to the pool.

The owner cannot recover the staking token or rewards token. Once a reward is
funded, it cannot be pulled back through `recoverERC20`.

## Observable state

Useful read methods include:

- `totalSupply()` and `balanceOf(account)` for measured stakes;
- `earned(account)` for the current claimable reward;
- `rewardPerToken()`, `rewardRate`, and `periodFinish` for the active schedule;
- `unlockAt(account)` for withdrawal eligibility; and
- `factory.poolCount()` and `factory.pools(index)` for discovery.

## Dependency pins

| Dependency | Commit |
|---|---|
| Foundry standard library | `c179529c064588ede54a0661ec3cc98219460d07` |
| OpenZeppelin Contracts | `5fd1781b1454fd1ef8e722282f86f9293cacf256` |

## Tests

The suite covers creation fees, proportional rewards, protocol skims, optional
locks, owner-only funding, reward solvency bounds, withdrawals, exits, and
recovery restrictions.

```bash
forge fmt --check
forge test -vv
forge build --sizes
```

## Related repositories

- [Token](https://github.com/ArchLiquid/archliquid-token)
- [Vesting](https://github.com/ArchLiquid/archliquid-vesting)
- [Integration contracts](https://github.com/ArchLiquid/archliquid-contracts)

## Security

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability. Use GitHub's
private vulnerability reporting flow; do not publish exploit details in an
issue.

## License

Copyright (c) 2026 ArchLiquid. This repository is public source, not open
source. No permission to use, copy, modify, compile, deploy, or distribute the
materials is granted without prior written approval. See [LICENSE](LICENSE).
Files marked `LicenseRef-ArchLiquid-Proprietary` are governed by that license.
