# Audit brief

What $COMPANY does, what it must guarantee, and where reviewers should look hardest. Everything referenced is in this repository. Nothing is deployed yet.

## 1. The system

The Zero Person Billion Dollar Company ($COMPANY) is one fixed-supply token on **Robinhood Chain** (chain ID 4663, an Arbitrum Orbit L2), traded in one **Uniswap v4** pool against **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, a LayerZero OFT).

- The whole supply (1,000,000,000) is single-sided liquidity owned by `CompanyHook`, which has no function to remove it. The hook is also the pool's v4 hook and blocks other pools and outside liquidity.
- The hook charges **4% of the IMD side of every swap**, through any router: 1% protocol (`feeRecipient`), 3% holders. Pool LP fee is 0.
- `CompanyToken.distribute()` splits each holder-fee arrival: **50% credited in IMD**, **10% reserved per stock** for NVDA, GOOGL, AAPL, GME and MSTR (Robinhood Stock Tokens, which have per-address blocklists).
- Reserves are converted IMD → USDG → stock through fixed hookless v4 pools (`CompanyConfig.sol` lists them with their ids), **at the start of every `claim()`** or by anyone through `convert()`. One round spends at most `maxConvert()` = 0.25% of the IMD/USDG pool's virtual IMD depth, shared by the five stocks; each stock converts at most once per minute. Each stock runs in its own `try this.convertStock{gas: CONVERT_GAS}(...)`; when a purchase fails, that round's IMD for the stock is credited to holders as IMD at once (`_fallBackToImd`). With too little gas left for a full `CONVERT_GAS` the stock is skipped (never fallen back), so a caller can't starve purchases to force the fallback, and a claim never fails on it. Every purchase must also receive at least 97% of what the Chainlink stock/USD and USDG/USD feeds imply (`minStockOut`), otherwise it reverts `PriceOff` and the stock is skipped this round; a stale or missing feed (older than 4 days) holds the stock. A stock pool with no liquidity at its price (`stockRoundLimit` = 0) has the round credited as IMD without a swap.
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
4. **Conversion can't be profitably sandwiched or drained:** the per-round cap, the per-stock 1-minute spacing (many claims in one transaction convert once), the self-call isolation, the fixed 20 IMD round ceiling (`MAX_ROUND_IMD`) on top of the `maxConvert` depth read, and the per-stock pool limit (`stockRoundLimit`). Can a round be made to sell more than its ceiling or limits?
5. **Minimum holding:** `eligibleSupply` always equals the sum of weights; crossing 100,000 either way never changes rewards already earned.
6. **Expiry:** `recycle` never moves more than `expiredRewardsOf`, and only to `feeRecipient`.
7. **Blocked stocks or holders** (stock tokens revert on blocked addresses): a refused payout stays claimable and never blocks the other assets, a claim, or a trade; a stock that can't be bought falls back to IMD one capped round at a time, and only on a real failure, never because the caller sent too little gas.
8. **No privileged control over balances, fees or transfers:** the token's owner is renounced; the hook owner can only `openPool` once and change `feeRecipient`.

## 4. Resolved: IMD Swarm audit 78c00339 (on commit 9fe5e93)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | High: just-in-time liquidity inflates `maxConvert()` and makes sandwiching profitable | Fixed ceiling `MAX_ROUND_IMD` = 20 IMD per round; `test_audit1_jitLiquidityCannotInflateRound` replays the attack (round ≤ 20 IMD, attacker loses). |
| 2 | Low: the USDG → stock hop is sized only by the IMD/USDG pool | `stockRoundLimit(asset)`: half the stock pool's fee × its virtual USDG depth, priced in IMD; `test_audit2_thinStockPoolLimitsItsRound`. |
| 3 | Low: partial fills of IMD-specified swaps overpay the fee or Panic | Hook reverts `PartialFill` unless the swap filled completely; the event amount can't underflow; `test_audit3_partialFillIsRejected_fullFillWorks`. |
| 4 | Low: anyone can reset any wallet's expiry timer by moving 1 wei out of the PoolManager | Receipts from the PoolManager no longer count as activity (buying alone isn't activity); `test_audit4_poolManagerPingDoesNotResetTimer`. |
| 5 | Low: `releaseStuckReserve` fires on an idle, healthy stock | Function removed: a failed purchase now credits that round's IMD to holders at once (`_fallBackToImd`, gas-bounded). |
| 6 | Low: stock is credited to holders at conversion time, not fee time | Accepted design limit, documented in the contract notice and README (conversions run at most a minute apart on every claim). |
| 7 | Info: stock already bought is frozen if its token blocks this contract | No in-contract fix possible; documented in the contract notice. |
| 8 | Info: expired stock goes to the claimer when the fee recipient is blocked | Refused expired amounts stay in `recycledHeld` for `sendRecycled`; `test_audit8_expiredStockHeldWhenFeeRecipientBlocked`. |
| 9 | Info: ETH-router trades logged with tx.origin | The hook decodes the user from hookData for both routers; `test_audit9_ethRouterTradeLogsRealBuyer`. |

## 5. Resolved: IMD Swarm re-check f1d5def3 (on commit ece5d4c)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | Medium: `stockRoundLimit` reads same-transaction liquidity, so JIT liquidity re-enables sandwiching a thin stock pool | Every purchase must receive ≥ 97% of what Chainlink's stock/USD and USDG/USD feeds imply (`minStockOut`, checked in `unlockCallback`); otherwise `PriceOff` and the stock is skipped this round. AMC had no feed and was replaced by GME. `test_recheck1_oracleStopsJitSandwichOfThinStockPool` replays the report's sequence (round skipped, attacker loses); also `test_recheck1_priceAwayFromOracle_skipsOnlyThatStock`, `test_recheck1_staleFeed_holdsThatStock`. |
| 2 | Low: a zero `stockRoundLimit` removed the limit and the swap crossed to a far resting position | Zero limit: the round is credited as IMD without any swap; `test_recheck2_zeroLiquidityRoundPaidAsImd_noSwap`. |
| 3 | Low: `NotEnoughGas` made claims fail when a round became due after the gas estimate | Too little gas now skips the stock (no fallback, no revert); `test_lowGasClaim_succeeds_skipsStocks_neverTurnsThemIntoImd`. The website sends claims with a high gas limit so purchases run. |
| 4 | Info: README described the removed 30-day release and an old test count | Updated. |
| 5 | Info: AUDIT.md listed "a router buy resets the expiry timer" as accepted | Removed: a buy is not activity since fix 4 of 78c00339. |

## 6. Known and accepted

- **Expiry estimate** (the same design was reviewed in IMD Swarm job cbe092d6, finding 1): "recent" rewards use the current weight, so a gift after a distribution can delay older rewards' expiry by up to 7 days, to nobody's gain. Documented in the contract notice.
- Dividend sniping around large trades; fees from other routers reach holders at the next flush, so that trader can share in its own fee.
- The IMD → USDG hop has no oracle (IMD has no Chainlink feed); it rests on the 20 IMD round ceiling and the IMD/USDG pool's depth. The stock hop is checked against Chainlink. Fixed routes can't be changed after deployment.
- Anyone able to make a purchase fail on purpose (e.g. an LP pulling a stock pool's liquidity in the same transaction) can turn that round's stock share into IMD; holders still receive its full value in IMD.
- A reverse split of a stock token that shrinks this contract's balance would leave the last claimers short.
- Stock tokens are restricted for US persons and filtered at the sequencer; not modelled in tests.
