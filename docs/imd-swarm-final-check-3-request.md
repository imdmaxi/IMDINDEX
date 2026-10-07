# IMD Swarm final check 3 request

After final check 2 [882666b4](https://explorer.imd.fun/jobs/882666b4-08cf-476b-ac4f-7c2e44399300). Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `0e125461b1ae97f99f4e1f8c965bd10747a87f2e`

## Request text

```text
Final check 3 for The Zero Person Billion Dollar Company ($COMPANY) on Robinhood Chain (4663), after IMD Swarm audit 78c00339, re-check f1d5def3, final check 363ab052 and final check 2 882666b4. AUDIT.md sections 4 to 7 map every finding to its fix and its test.

What the contracts are for: CompanyToken is a fixed 1,000,000,000 supply ERC-20; its ownership is renounced in the constructor. CompanyHook owns the token's only Uniswap v4 pool, paired with IMD, with liquidity locked forever, and takes 4% of every swap in that pool: 1% to the protocol, 3% to holders. Holder fees are split 50% IMD and 10% each to NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim(), with each purchase checked against Chainlink. Only wallets holding at least 100,000 earn. If a wallet goes more than 7 days without claiming, buying, selling or sending, its unclaimed rewards older than 7 days expire.

Changed since 882666b4; review these hardest:
1. Root-cause fix for the flash-borrow expiry bypass (findings 1 and 2): _transfer records in transient storage the $COMPANY each address received from the PoolManager in the current transaction (FROM_POOL_SEED; moved along when forwarded, reduced when returned), and expiredRewardsOf leaves that amount out of the weight used for "recent" rewards. Can a borrowed balance still count, through any path (forwarding chains, system accounts, transferFrom, routers, markActive)? Can the tag ever make a transfer revert, or expire rewards an honest holder earned in the last 7 days?
2. The IMD/USDG pool counts as empty while maxConvert() is below 1% of a full round (0.2 IMD), and the empty clock (imdPoolEmptySince) restarts unless re-confirmed within a day (imdPoolLastSeenEmpty).
3. feedLastGood: an unusable feed (revert, answer <= 0) is dead only after DEAD_AFTER without a usable answer.

Please confirm these, check that nothing broke the solvency of the six reward assets, the flash-borrow guard, the 100,000 minimum, expiry or the scanner-relevant properties (no external calls in transfers), and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork test (live Chainlink feeds and pools): FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
