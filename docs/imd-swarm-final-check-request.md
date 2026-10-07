# IMD Swarm final check request

After audit [78c00339](https://explorer.imd.fun/jobs/78c00339-8764-4684-920c-0958d23472c0) and re-check [f1d5def3](https://explorer.imd.fun/jobs/f1d5def3-c15d-4e7f-99cb-e0b0ebfdd584). Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Checked with `POST https://api.imd.fun/requests/check` on 2026-10-07: no blockers. Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `814d544059e38d090e7d2a6bd12fe6ef15b0528a`

## Request text

```text
Final check for The Zero Person Billion Dollar Company ($COMPANY) on Robinhood Chain (4663), after IMD Swarm audit 78c00339 and re-check f1d5def3. AUDIT.md sections 4 and 5 map every finding to its fix and test.

What the contracts are for: CompanyToken is a fixed 1,000,000,000 supply ERC-20; its ownership is renounced in the constructor. CompanyHook owns the token's only Uniswap v4 pool, paired with IMD, with liquidity locked forever, and takes 4% of every swap: 1% to the protocol, 3% to holders. Holder fees are split 50% IMD and 10% each to NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim(). Only wallets holding at least 100,000 earn, and unclaimed rewards expire after 7 days.

Changed since the re-check, review these hardest:
1. Chainlink check on the stock hop (fix for re-check finding 1): minStockOut(asset, usdIn) uses the stock/USD and USDG/USD feeds (8 decimals, max age 4 days, 3% tolerance) and is enforced in unlockCallback (revert PriceOff); _convertAll skips the stock on PriceOff or a stale feed, and falls back to IMD only on other failures. Can a caller force PriceOff or the fallback, or get a purchase through at a manipulated price? Are the decimals (USDG 6, stocks 18, read at deployment) and stale-feed handling right?
2. GME (0x1b0E319c6A659F002271B69dB8A7df2F911c153E, the official Robinhood token) replaces AMC, which has no feed. Its v4 USDG pool (fee 1%, spacing 200, id 0x3d436b4f...063b) is thin (about $6k), so stockRoundLimit binds near 3.4 IMD per round.
3. A zero stockRoundLimit now credits the round as IMD without swapping (re-check finding 2).
4. Too little gas skips the stock instead of reverting (re-check finding 3).

Please confirm these, check that nothing broke solvency of the six assets, the flash-borrow guard, the 100,000 minimum, expiry or the scanner-relevant properties, and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork test (live feeds and pools): FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
