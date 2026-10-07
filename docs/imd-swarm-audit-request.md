# IMD Swarm audit request

Ready to paste at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**). Checked with `POST https://api.imd.fun/requests/check` on 2026-10-07: no blockers; plan is four specialist auditors (math, permissions, economics, control flow) and a judge. Price: 0.5 IMD on Ethereum mainnet.

- **Repository:** https://github.com/imdmaxi/IMDINDEX
- **Commit:** `a85bf3066af9f0368c4d9b18962c4ba53d31083c`

## Request text

```text
Project: The Zero Person Billion Dollar Company ($COMPANY), pre-launch audit.

Repo: github.com/imdmaxi/IMDINDEX (commit a85bf30). Read AUDIT.md first: it states the system, the guarantees and the known, accepted limits.

Scope: contracts/src/CompanyToken.sol, contracts/src/CompanyHook.sol, contracts/src/CompanyRouter.sol, contracts/src/CompanyEthRouter.sol, contracts/src/lib/SafeTransfer.sol, contracts/script/CompanyConfig.sol, contracts/script/DeployLib.sol.

Tests: contracts/test/Company.t.sol (cd contracts; git submodule update --init --recursive; forge test), contracts/test/Company.fork.t.sol (FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest).

What it is: one fixed-supply token in a Uniswap v4 pool against IMD on Robinhood Chain (4663). The hook takes 4% of the IMD side of every swap: 1% protocol, 3% holders. Holder fees are split 50% IMD, 10% each to NVDA, GOOGL, AAPL, AMC and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim() (or convert()), capped at 0.25% of the IMD/USDG pool's IMD depth per round, each stock at most once a minute, each in an isolated self-call. Only wallets holding >= 100,000 earn. 7-day expiry of unclaimed rewards to feeRecipient. Token ownership renounced in the constructor. Deploy config (contracts/script/CompanyConfig.sol): fee recipient and hook owner 0x8F5A29c82e8285Db3B2af8D0caF5404b0f9ce834, start market cap 306 IMD.

Please verify above all: solvency of all six assets; no reward capture with flash-borrowed pool tokens or from one's own trade; that conversion cannot be sandwiched profitably, inflated past its cap, or made to run more than once per stock per block; that a blocked stock or blocked holder can never block claims, trades or the other assets; eligibleSupply equals the sum of weights across the 100,000 threshold; recycle never exceeds expiredRewardsOf; and that nothing can change balances, fees or transfers (scanner flags: honeypot, hidden owner, owner can change balance, suspicious function).
```

## Same request as an API body (`job.open`)

```json
{
  "objective": "Project: The Zero Person Billion Dollar Company ($COMPANY), pre-launch audit.\n\nRepo: github.com/imdmaxi/IMDINDEX (commit a85bf30). Read AUDIT.md first: it states the system, the guarantees and the known, accepted limits.\n\nScope: contracts/src/CompanyToken.sol, contracts/src/CompanyHook.sol, contracts/src/CompanyRouter.sol, contracts/src/CompanyEthRouter.sol, contracts/src/lib/SafeTransfer.sol, contracts/script/CompanyConfig.sol, contracts/script/DeployLib.sol.\n\nTests: contracts/test/Company.t.sol (cd contracts; git submodule update --init --recursive; forge test), contracts/test/Company.fork.t.sol (FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest).\n\nWhat it is: one fixed-supply token in a Uniswap v4 pool against IMD on Robinhood Chain (4663). The hook takes 4% of the IMD side of every swap: 1% protocol, 3% holders. Holder fees are split 50% IMD, 10% each to NVDA, GOOGL, AAPL, AMC and MSTR Robinhood stock tokens, bought IMD -> USDG -> stock at the start of every claim() (or convert()), capped at 0.25% of the IMD/USDG pool's IMD depth per round, each stock at most once a minute, each in an isolated self-call. Only wallets holding >= 100,000 earn. 7-day expiry of unclaimed rewards to feeRecipient. Token ownership renounced in the constructor. Deploy config (contracts/script/CompanyConfig.sol): fee recipient and hook owner 0x8F5A29c82e8285Db3B2af8D0caF5404b0f9ce834, start market cap 306 IMD.\n\nPlease verify above all: solvency of all six assets; no reward capture with flash-borrowed pool tokens or from one's own trade; that conversion cannot be sandwiched profitably, inflated past its cap, or made to run more than once per stock per block; that a blocked stock or blocked holder can never block claims, trades or the other assets; eligibleSupply equals the sum of weights across the 100,000 threshold; recycle never exceeds expiredRewardsOf; and that nothing can change balances, fees or transfers (scanner flags: honeypot, hidden owner, owner can change balance, suspicious function).",
  "template": "audit",
  "repoUrl": "https://github.com/imdmaxi/IMDINDEX.git",
  "baseCommit": "a85bf3066af9f0368c4d9b18962c4ba53d31083c"
}
```
