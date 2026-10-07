# IMD Swarm final check 4 request

After final check 3 [986abba2](https://explorer.imd.fun/jobs/986abba2-68de-47d2-be7e-4c68f5525e3b). Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `b4e3cde2ffe2a9b69841c70cadf4d7325a0e8b10`

## Request text

```text
Final check 4 for The Zero Person Billion Dollar Company ($COMPANY) on Robinhood Chain (4663), after IMD Swarm audit 78c00339, re-check f1d5def3 and final checks 363ab052, 882666b4 and 986abba2. AUDIT.md sections 4 to 8 map every finding to its fix and its test.

What the contracts are for: CompanyToken is a fixed 1,000,000,000 supply ERC-20; its ownership is renounced in the constructor. CompanyHook owns the token's only Uniswap v4 pool, paired with IMD, with liquidity locked forever, and takes 4% of every swap in that pool: 1% to the protocol, 3% to holders. Holder fees are split 50% IMD and 10% each to NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim(). Only wallets holding at least 100,000 earn. If a wallet goes more than 7 days without claiming, buying, selling or sending, its unclaimed rewards older than 7 days expire.

Changed since 986abba2; review these hardest:
1. The IMD -> USDG hop is now checked too: minUsdOut(imdIn) prices IMD via the IMD/ETH pool (fee 1%, spacing 100, no hooks) and Chainlink ETH/USD and USDG/USD, less the IMD/USDG pool fee and IMD_TOLERANCE_BPS (10%); unlockCallback reverts PriceOff below it and the stock is skipped. Can a round still sell at a made-up price, or can the check be pushed (the IMD/ETH spot is read in the same transaction) to block or force anything? The 10% reflects IMD's two pools drifting about 5.6% apart after a 2 ETH buy on a fork.
2. One stuck rule replaces the dead-feed and empty-pool clocks: waitingSince[stock] starts when a reserve fills from empty (distribute), moves to now on every successful purchase (convertStock), clears when the reserve empties; a stock waiting more than DEAD_AFTER (30 days) is paid as IMD one capped round at a time, whatever blocks it (stale or unusable feed, empty IMD/USDG pool, PriceOff). Can anyone trigger it early on a healthy stock, or keep a stuck stock from ever falling back?
3. claim() now handles expiry (_recycle, lastActive) before flush and _convertAll; from-pool tags lapse after any distribution in the transaction (transient epoch bumped in _credit).
4. The IMD/USDG pool counts as empty below 1% of a full round; then nothing is swapped and only stuck stocks fall back.

Please confirm these, check that nothing broke the solvency of the six reward assets, the flash-borrow guards, the 100,000 minimum, expiry or the scanner-relevant properties (no external calls in transfers), and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork test (live Chainlink feeds and pools): FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
