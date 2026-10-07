# Audit brief

What $COMPANY does, what it must guarantee, and where reviewers should look hardest. Everything referenced is in this repository. Nothing is deployed yet.

## 1. The system

The Zero Person Billion Dollar Company ($COMPANY) is one fixed-supply token on **Robinhood Chain** (chain ID 4663, an Arbitrum Orbit L2), traded in one **Uniswap v4** pool against **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, a LayerZero OFT).

- The whole supply (1,000,000,000) is single-sided liquidity owned by `CompanyHook`, which has no function to remove it. The hook is also the pool's v4 hook and blocks other pools and outside liquidity.
- The hook charges **4% of the IMD side of every swap**, through any router: 1% protocol (`feeRecipient`), 3% holders. Pool LP fee is 0.
- `CompanyToken.distribute()` splits each holder-fee arrival: **50% credited in IMD**, **10% reserved per stock** for NVDA, GOOGL, AAPL, AMC and MSTR (Robinhood Stock Tokens, which have per-address blocklists).
- Reserves are converted IMD → USDG → stock through fixed hookless v4 pools (`CompanyConfig.sol` lists them with their ids), **at the start of every `claim()`** or by anyone through `convert()`. One round spends at most `maxConvert()` = 0.25% of the IMD/USDG pool's virtual IMD depth, shared by the five stocks; each stock converts at most once per minute. Each stock runs in its own `try this.convertStock(...)` so a failing stock is skipped.
- Only wallets holding **≥ 100,000 $COMPANY** earn (`MIN_HOLDING`): earning weight is the balance, or 0 below it.
- Unclaimed rewards of wallets inactive for > 7 days expire to `feeRecipient` (except the last 7 days' earnings).
- No owner on the token (renounced in the constructor), no mint, no upgradeability.

## 2. Scope

| File | Role |
| --- | --- |
| `contracts/src/CompanyToken.sol` | ERC-20 + EIP-2612, six-asset rewards (magnified per-share per asset), minimum holding, expiry, conversion |
| `contracts/src/CompanyHook.sol` | Pool owner and v4 hook: fee, one-time `openPool`, locked liquidity, `flush`, `collectProtocolFees` |
| `contracts/src/CompanyRouter.sol`, `contracts/src/CompanyEthRouter.sol` | Buy/sell with IMD or ETH (via the v4 IMD/ETH pool); `flush` before the buyer receives tokens |
| `contracts/src/lib/SafeTransfer.sol` | Transfer helpers |
| `contracts/script/DeployLib.sol`, `CompanyConfig.sol`, `Deploy.s.sol` | Start tick, hook salt mining, mainnet addresses and pool keys |

Tests: `contracts/test/Company.t.sol` (unit, attack and fuzz against a real `PoolManager`), `contracts/test/Company.fork.t.sol` (live mainnet state: `FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest`).

## 3. Guarantees to check

1. **Solvency, every asset:** IMD held ≥ `owed[0]` + Σ `pendingConvert`; each stock held ≥ `owed[stock]`; Σ withdrawable ≤ `owed`.
2. **No one earns from their own trade** through `CompanyRouter`/`CompanyEthRouter` (flush happens before the buyer receives tokens).
3. **Flash-borrowed pool tokens never earn:** nothing is credited while another caller has the `PoolManager` unlocked; `convert` cannot run inside a foreign unlock.
4. **Conversion can't be profitably sandwiched or drained:** the per-round cap, the per-stock 1-minute spacing (many claims in one transaction convert once), the self-call isolation, and the `maxConvert` depth read. Can the cap be inflated, or a round made to sell more than 0.25% of depth?
5. **Minimum holding:** `eligibleSupply` always equals the sum of weights; crossing 100,000 either way never changes rewards already earned.
6. **Expiry:** `recycle` never moves more than `expiredRewardsOf`, and only to `feeRecipient`.
7. **Blocked stocks or holders** (stock tokens revert on blocked addresses): a refused payout stays claimable and never blocks the other assets, a claim, or a trade; a stock blocked for 30 days can be released to IMD holders.
8. **No privileged control over balances, fees or transfers:** the token's owner is renounced; the hook owner can only `openPool` once and change `feeRecipient`.

## 4. Known and accepted

- **Expiry estimate** (the same design was reviewed in IMD Swarm job cbe092d6, finding 1): "recent" rewards use the current weight, so a gift after a distribution can delay older rewards' expiry by up to 7 days, to nobody's gain. Documented in the contract notice.
- A buy delivered by a router to another address resets that address's expiry timer (costs the buyer 4%).
- Dividend sniping around large trades; fees from other routers reach holders at the next flush, so that trader can share in its own fee.
- Conversion has no minimum output; safety rests on the cap and spacing. Fixed routes can't be changed after deployment.
- A reverse split of a stock token that shrinks this contract's balance would leave the last claimers short.
- Stock tokens are restricted for US persons and filtered at the sequencer; not modelled in tests.
