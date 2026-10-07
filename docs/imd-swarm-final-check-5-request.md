# IMD Swarm final check 5 request (optional)

After final check 4 [dddb75ec](https://explorer.imd.fun/jobs/dddb75ec-5081-49b8-9204-f4de1725ca03). Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `c941b17cdbf617892acfb2fc58a59d1482ee09f9`

## Request text

```text
Final check 5 for The Zero Person Billion Dollar Company ($COMPANY) on Robinhood Chain (4663), after IMD Swarm audit 78c00339, re-check f1d5def3 and final checks 363ab052, 882666b4, 986abba2 and dddb75ec. AUDIT.md sections 4 to 9 map every finding to its fix and its test.

What the contracts are for: CompanyToken is a fixed 1,000,000,000 supply ERC-20; its ownership is renounced in the constructor. CompanyHook owns the token's only Uniswap v4 pool, paired with IMD, with liquidity locked forever, and takes 4% of every swap in that pool: 1% to the protocol, 3% to holders. Holder fees are split 50% IMD and 10% each to NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim(), each step checked against a reference price. Only wallets holding at least 100,000 earn. If a wallet goes more than 7 days without claiming, buying, selling or sending, its unclaimed rewards older than 7 days expire.

Changed since dddb75ec; review these hardest:
1. Fallback size: every IMD fallback now pays min(pendingConvert, MAX_ROUND_IMD / 5), never a swap-clipped amount; a successful purchase below a tenth of a round doesn't reset the stuck clocks.
2. Stuck rule: failingSince[stock] is set on the first skipped or failed attempt since the last real purchase (stale feed, IMD/USDG pool unusable, PriceOff, dust purchase) and cleared by a real purchase; _skipOrFallBack pays as IMD only when waitingSince is more than DEAD_AFTER (30 days) old AND failingSince at least a day old. Can a healthy stock still be paid as IMD early, or a broken one be kept from ever falling back?
3. IMD/USDG pool usability: usable only with maxConvert() >= 1% of a round AND its spot within IMD_TOLERANCE_BPS (10%) of IMD's reference (IMD/ETH pool + Chainlink ETH/USD and USDG/USD); stockRoundLimit prices USDG->IMD at that reference; an IMD/USDG-side fill failure reverts PriceOff (skip), so only stock-side failures fall back at once.
4. _swapFee: minUsdOut and minStockOut subtract the LP fee plus Uniswap's protocol fee for the swap's direction (0.1% is on for IMD/USDG and GME/USDG on Robinhood Chain).

Please confirm these, check that nothing broke the solvency of the six reward assets, the flash-borrow guards, the 100,000 minimum, expiry or the scanner-relevant properties (no external calls in transfers), and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork test (live Chainlink feeds, pools and protocol fees): FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
