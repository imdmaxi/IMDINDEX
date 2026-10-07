# IMD Swarm re-check request

Re-check of audit [78c00339](https://explorer.imd.fun/jobs/78c00339-8764-4684-920c-0958d23472c0) after the fixes. Paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Checked with `POST https://api.imd.fun/requests/check` on 2026-10-07: no blockers; four specialist auditors and a judge. Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `dcb313614cba790ec835136b6cbbc6eca016a4de`

## Request text

```text
Re-check of IMD Swarm audit 78c00339 (which audited commit 9fe5e93) for The Zero Person Billion Dollar Company ($COMPANY), Robinhood Chain (4663).

Repo: github.com/imdmaxi/IMDINDEX (commit dcb3136). AUDIT.md section 4 maps each finding to its fix and its test.

Fixes to verify:
1 (high) JIT liquidity inflating maxConvert(): fixed per-round ceiling MAX_ROUND_IMD = 20 IMD (CompanyToken.maxConvert). Test: test_audit1_jitLiquidityCannotInflateRound replays your sequence.
2 (low) USDG -> stock hop: per-stock limit stockRoundLimit(asset) = half the stock pool fee x its virtual USDG depth, priced in IMD. Test: test_audit2_thinStockPoolLimitsItsRound.
3 (low) partial fills: CompanyHook.afterSwap reverts PartialFill unless an IMD-specified swap filled completely; the Trade amount is clamped. Test: test_audit3_partialFillIsRejected_fullFillWorks.
4 (low) free timer reset: receipts from the PoolManager no longer count as activity. Test: test_audit4_poolManagerPingDoesNotResetTimer.
5 (low) releaseStuckReserve was removed after your commit: a failed stock purchase now credits that round's IMD to holders at once (_fallBackToImd) inside a gas-bounded self-call (CONVERT_GAS); a claim with too little gas reverts NotEnoughGas. Please review this new path.
6 (low) and 7 (info): accepted and documented in the CompanyToken notice and README.
8 (info): refused expired rewards stay in recycledHeld for sendRecycled. Test: test_audit8_expiredStockHeldWhenFeeRecipientBlocked.
9 (info): the Trade event decodes the user for both routers. Test: test_audit9_ethRouterTradeLogsRealBuyer.

Please confirm each fix, check that none of them broke solvency of the six assets, the flash-borrow guard, the 100,000 minimum, expiry or the scanner-relevant properties, and report anything new.

Tests: cd contracts; git submodule update --init --recursive; forge test. Fork: FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest.
```
