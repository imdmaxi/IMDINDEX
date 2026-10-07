# IMD Swarm final check 2 request

After final check [363ab052](https://explorer.imd.fun/jobs/363ab052-8299-402c-8111-849a10d68da1). Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `34eff8bd196a0837375a3d77daf875174f932272`

## Request text

```text
Final check 2 for The Zero Person Billion Dollar Company ($COMPANY) on Robinhood Chain (4663), after IMD Swarm audit 78c00339, re-check f1d5def3 and final check 363ab052. AUDIT.md sections 4 to 6 map every finding to its fix and its test.

What the contracts are for: CompanyToken is a fixed 1,000,000,000 supply ERC-20; its ownership is renounced in the constructor. CompanyHook owns the token's only Uniswap v4 pool, paired with IMD, with liquidity locked forever, and takes 4% of every swap in that pool: 1% to the protocol, 3% to holders. Holder fees are split 50% IMD and 10% each to NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim(), with each purchase checked against Chainlink. Only wallets holding at least 100,000 earn, and unclaimed rewards expire after 7 days.

Changed since 363ab052; review these hardest:
1. _transfer now forfeits the expired rewards of a sender (or of a receiver that pulled with transferFrom) who has been inactive for more than 7 days, into recycledHeld, before the timer resets (bookkeeping only, no external call). Check solvency, the weight and correction order in _transfer, and that no transfer can revert or be blocked by it.
2. claim() and recycle() revert while the PoolManager is unlocked.
3. A feed dead or unusable for DEAD_AFTER (30 days), or an IMD/USDG pool with no liquidity at its price for 30 days (imdPoolEmptySince), now pays rounds as IMD. Can anyone trigger this early, or keep a healthy stock from converting?
4. A stock pool that can take less than 1% of a round now counts as empty and the round is paid as IMD.
5. minStockOut removes the pool's own fee before the 3% tolerance.

Please confirm these, check that nothing broke the solvency of the six reward assets, the flash-borrow guard, the 100,000 minimum, expiry or the scanner-relevant properties (no external calls in transfers), and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork test (live Chainlink feeds and pools): FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
