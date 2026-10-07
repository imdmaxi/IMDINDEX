# Audit brief

What $COMPANY does, what it must guarantee, and where reviewers should look hardest. Everything referenced is in this repository. Nothing is deployed yet.

## 1. The system

The Zero Person Billion Dollar Company ($COMPANY) is one fixed-supply token on **Robinhood Chain** (chain ID 4663, an Arbitrum Orbit L2), traded in one **Uniswap v4** pool against **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, a LayerZero OFT).

- The whole supply (1,000,000,000) is single-sided liquidity owned by `CompanyHook`, which has no function to remove it. The hook is also the pool's v4 hook and blocks other pools *that use this hook* and outside liquidity in its pool. It can't stop someone opening a separate, hookless $COMPANY pool elsewhere; swaps there pay no fee (see section 7).
- The hook charges **4% of the IMD side of every swap in its pool** (the pool holding the locked supply), through any router: 1% protocol (`feeRecipient`), 3% holders. Pool LP fee is 0.
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
7. **Blocked stocks or holders** (stock tokens revert on blocked addresses): a refused payout stays claimable and never blocks the other assets, a claim, or a trade; a stock whose token or pool refuses the purchase falls back to IMD at once; a stock blocked by a price, feed or IMD/USDG-pool problem falls back only after waiting 30 days without a real purchase and failing for at least a day; never because the caller sent too little gas.
8. **No privileged control over balances, fees or transfers:** the token's owner is renounced; the hook owner can only `openPool` once and change `feeRecipient`.

## 4. Resolved: IMD Swarm audit 78c00339 (on commit 9fe5e93)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | High: just-in-time liquidity inflates `maxConvert()` and makes sandwiching profitable | Fixed ceiling `MAX_ROUND_IMD` = 20 IMD per round; `test_audit1_jitLiquidityCannotInflateRound` replays the attack (round ≤ 20 IMD, attacker loses). |
| 2 | Low: the USDG → stock hop is sized only by the IMD/USDG pool | `stockRoundLimit(asset)`: half the stock pool's fee × its virtual USDG depth, priced in IMD; `test_audit2_thinStockPoolLimitsItsRound`. |
| 3 | Low: partial fills of IMD-specified swaps overpay the fee or Panic | Hook reverts `PartialFill` unless the swap filled completely; the event amount can't underflow; `test_audit3_partialFillIsRejected_fullFillWorks`. |
| 4 | Low: anyone can reset any wallet's expiry timer by moving 1 wei out of the PoolManager | Receipts from the PoolManager no longer count as activity by themselves; a real buy is recorded by the hook (`markActive`, hook-only, for the router-reported user or tx.origin), so it can't be faked for another wallet; `test_audit4_poolManagerPingDoesNotResetTimer`. |
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
| 5 | Info: AUDIT.md listed "a router buy resets the expiry timer" as accepted | Removed. A buy is activity only for the buyer the hook records (see 78c00339 finding 4), never for a recipient chosen by someone else. |

## 6. Resolved: IMD Swarm final check 363ab052 (on commit d624407)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | High: a self-transfer of 1 wei resets the timer and revives expired rewards | `_transfer` forfeits a returning sender's (or pulling receiver's) expired rewards into `recycledHeld` before resetting the timer: bookkeeping only, no external call in a transfer. `test_final1_selfTransferForfeitsExpiredFirst`. |
| 2 | High: claim inside a foreign unlock with flash-borrowed pool tokens dodges expiry | `claim()` and `recycle()` revert `Reentrancy` while the PoolManager is unlocked. `test_final2_claimWithBorrowedPoolTokensIsRefused`. The capital-backed gift variant is accepted (section 7). |
| 3 | Medium: a dead feed or an empty IMD/USDG pool locks a stock's reserve forever | After `DEAD_AFTER` (30 days) of a dead or unusable feed, or an IMD/USDG pool with no liquidity at its price (`imdPoolEmptySince`), rounds are paid to holders as IMD. `test_final3_deadFeedFallsBackToImdAfter30Days`, `test_final3_emptyImdPoolFallsBackToImdAfter30Days`. |
| 4 | Low: a dust position defeats the empty-pool fallback | A stock pool that can take less than 1% of a round counts as empty (round paid as IMD). `test_final4_dustPositionCountsAsEmpty`. |
| 5 | Low: inside the 3% tolerance a JIT sandwich of a thin stock pool can still skim | Accepted bound: at most about 3% of one stock's share of a round (≤ 4 IMD) per minute, only while that pool's in-range depth × fee is below one round. Not exploitable on any pool today. |
| 6 | Info: GME's 1% fee eats most of the 3% tolerance | The pool's own fee is removed from the Chainlink-implied amount before the 3% tolerance. `test_final6_poolFeeExcludedFromTolerance`. |
| 7 | Info: a separate hookless $COMPANY pool pays no fee | Inherent (the token has no transfer restrictions, which the scanners require). Documentation corrected: the fee applies to swaps in the hook's pool, which holds all the locked liquidity. |

## 7. Resolved: IMD Swarm final check 2 882666b4 (on commit 331230c)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | High: a send while holding flash-borrowed pool tokens revives expired rewards (live weight in `_forfeit`) | Root cause fixed: tokens an address received from the PoolManager in the current transaction (tracked in transient storage, moved when forwarded, cleared when returned) are left out of the weight used for "recent" rewards, so a borrowed balance never counts. No external call in transfers. `test_final2_1_flashBorrowThenSend_stillForfeits` (fails without the fix with the report's 0.6 IMD). |
| 2 | High: `markActive(tx.origin)` inside the swapper's own unlock after borrowing pool tokens | Closed by the same root-cause fix (`markActive` forfeits with the borrow-proof weight). `test_final2_2_flashBorrowThenDustBuy_stillForfeits`. |
| 3 | Medium: a dust IMD/USDG position keeps `maxConvert()` above 0 and stops the 30-day fallback | The pool counts as empty while `maxConvert()` < 1% of a full round (0.2 IMD). `test_final2_3_dustImdPoolStillCountsAsEmpty`. |
| 4 | Low: a feed unusable for one round is treated as dead at once | `feedLastGood` records the last usable answer; an unusable feed is dead only after `DEAD_AFTER` without one. `test_final2_4_unusableFeedHoldsUntilDeadAfter`. |
| 5 | Info: a contract wallet's buy through another router credits tx.origin | Documented (README): only the buyer our routers report, or the signing wallet, gets buy activity; contract wallets should claim, sell or send, or buy through the site. |
| 6 | Info: emptiness seen twice 30 days apart triggers the fallback | The empty clock restarts unless emptiness is re-confirmed within a day (`imdPoolLastSeenEmpty`). `test_final2_6_emptinessMustBeConfirmed`. |

## 8. Resolved: IMD Swarm final check 3 986abba2 (on commit 3b09bc7)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | Medium: in an empty IMD/USDG pool, a position at a made-up price clears the emptiness test and every round sells reserves into it for dust | The IMD → USDG hop is now checked against IMD's value via the IMD/ETH pool and Chainlink ETH/USD (`minUsdOut`, 10% tolerance after the pool fee); a round at a made-up price reverts `PriceOff` and is skipped. `test_final3_1_madeUpPricePositionGetsNothing` (sells 2.34 IMD without the check, as in the report; nothing with it). |
| 2 | Low: the from-pool tag also excluded the tagged tokens' share of distributions later in the same transaction | `claim()` handles expiry first, before it flushes or converts, so the tag is exact at that point; tags also lapse after any distribution in the transaction (transient epoch), erring in the holder's favour for a send after a flush. `test_final3_2_buyAndClaimSameTxKeepsFreshRewards`. |
| 3 | Low: `feedLastGood` was only written when a round ran | Removed with the per-feed dead logic (see 4). `test_final3_3_unusableReadAfterQuietMonthHolds`. |
| 4 | Low: the 30-day empty-pool fallback needed a daily keeper | One rule replaces the separate dead-feed and empty-pool clocks: `waitingSince[stock]` starts when a stock's reserve fills from empty, moves to now on every successful purchase and clears when the reserve empties; a stock waiting more than `DEAD_AFTER` (30 days) without a purchase has its rounds paid as IMD, whatever the reason. No keeper needed. `test_final3_emptyImdPoolFallsBackToImdAfter30Days`, `test_stuckClock_onlyCountsWaitingWithoutAPurchase`. |

## 9. Resolved: IMD Swarm final check 4 dddb75ec (on commit 9a4c338)

| # | Finding | Resolution |
| --- | --- | --- |
| 1 | Medium: the stuck fallback paid only the swap-clipped amount, so a dust position slowed it about 100× | Every fallback pays a full round, `min(pending, 4 IMD)`, never a swap-clipped amount; a purchase of less than a tenth of a round doesn't count as the stock working. `test_final4_1a_dustImdPositionDoesNotThrottleFallback`, `test_final4_1b_dustStockPoolDoesNotThrottleFallback`. |
| 2 | Low: after a quiet month, the first transient skip paid a healthy stock as IMD | `failingSince[stock]` records the first failed or skipped attempt since the last real purchase; a stock falls back only when it has waited 30 days *and* been failing for at least a day. `test_final4_2a_quietMonthThenStaleFeedDoesNotPay`, `test_final4_2b_quietMonthThenImdEthPushDoesNotPay`. |
| 3 | Low: in an exhausted IMD/USDG pool, a single-sided IMD position made all stocks fall back at once | The IMD/USDG pool is usable only when its price is within 10% of IMD's reference; `stockRoundLimit` prices USDG→IMD at the reference; an IMD/USDG-side fill failure is reported as `PriceOff` (skip), so only stock-side failures fall back at once. `test_final4_3_singleSidedImdPositionDoesNotForceFallback`. |
| 4 | Info: Uniswap's 0.1% protocol fee is on for the route pools | Both minimums subtract the swap fee actually charged (`_swapFee`: LP fee and protocol fee for that direction). `test_final4_4_protocolFeeCountsInPriceChecks`. |
| 5 | Info: README and NatSpec misstated the price checks and depth | Corrected. |
| 6 | Info: no tests for the first-hop drift skip or stale ETH/USD and USDG/USD feeds | `test_final4_6a_imdEthDriftSkipsEverything`, `test_final4_6b_staleEthOrUsdgFeedHoldsEverything`. |

## 10. Known and accepted

- **Expiry estimate** (the same design was reviewed in IMD Swarm job cbe092d6, finding 1): "recent" rewards use the current weight. A gift received after a distribution can delay older rewards' expiry by up to 7 days. Combined with a claim, a round-trip gift from an accomplice can save an inactive wallet's own backlog (audit 363ab052, finding 2, gift variant). That needs real capital (roughly backlog / recent per-share growth in tokens), never touches other holders, and only reduces what the fee recipient collects. The flash-loan variants are closed: claim and recycle refuse to run mid-unlock, and tokens received from the PoolManager in the current transaction never count toward "recent" rewards.
- Dividend sniping around large trades; fees from other routers reach holders at the next flush, so that trader can share in its own fee.
- The IMD → USDG hop is checked against IMD's value via the IMD/ETH pool and Chainlink ETH/USD with a 10% tolerance (IMD has no feed of its own; its two pools can drift apart until arbitraged). Within that tolerance, sandwiches stay bounded by the 20 IMD round ceiling. The stock hop is checked against Chainlink (3%). Fixed routes and feeds can't be changed after deployment.
- After a large buy through the ETH route, IMD's two pools can be several percent apart until arbitrage realigns them; stock rounds that would exceed the tolerance are skipped and wait.
- Within the 3% oracle tolerance (after the pool fee), a sandwich of a thin stock pool can skim at most about 3% of that stock's round.
- Anyone can open a separate, hookless $COMPANY pool; swaps there pay no fee.
- Anyone able to make a purchase fail on purpose (e.g. an LP pulling a stock pool's liquidity in the same transaction) can turn that round's stock share into IMD; holders still receive its full value in IMD.
- A reverse split of a stock token that shrinks this contract's balance would leave the last claimers short.
- Stock tokens are restricted for US persons and filtered at the sequencer; not modelled in tests.
