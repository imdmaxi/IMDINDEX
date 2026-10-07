# Scanner review request (template)

Send this to GoPlus (and adapt for Quick Intel) only if a scan of the deployed token shows a flag. Fill in the `<…>` fields from `contracts/deployments/robinhood.json` after deployment, and check every statement against the deployed, verified code before sending. Leave out the audit section until an audit exists.

---

Token: The Zero Person Billion Dollar Company (symbol: COMPANY)
Chain: Robinhood Chain (chain ID 4663)
Contract: `<token address>`
Verified source: https://robinhoodchain.blockscout.com/address/`<token address>` (also on Sourcify)
Repository: https://github.com/imdmaxi/IMDINDEX (file `contracts/src/CompanyToken.sol`)
Website: https://www.zeropersoncompany.fun

Request: please review the flag(s) `<flag names>`. We believe they are false positives.

## 1. Ownership is renounced, and no one can change balances

- The contract stores an `owner` variable. The constructor sets it to the deployer and immediately renounces it, emitting `OwnershipTransferred(0x0, deployer)` and `OwnershipTransferred(deployer, 0x0)` in the deployment transaction. `owner()` returns `0x0`.
- No function in the token checks the owner, and nothing can ever set it again.
- Balances change in only two places: the constructor, which assigns the fixed supply of 1,000,000,000 once (to the hook contract, which locks it in the pool), and the internal `_transfer`, which subtracts from the sender and adds to the recipient.
- There is no mint, burn, pause, blacklist, whitelist, max-transaction limit, cooldown, trading switch or adjustable fee. The contract is not a proxy and has no `selfdestruct` or `delegatecall`.
- `transferFrom` uses the standard allowance for every spender. No address is exempt.

## 2. Selling works, with a fixed 4% fee

- COMPANY trades on Uniswap v4 against IMD (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`) in one pool whose hook is `<hook address>`.
- The hook charges a fixed 4% of the IMD side of every buy and sell: 3% goes to holders and 1% to the protocol. Nobody can change it. Wallet-to-wallet transfers pay nothing.
- Nothing in the token or the hook can block a sell or treat wallets differently.
- All liquidity is owned by the hook, which has no function to remove it. It is locked permanently.
- Sells by many different wallets are visible in the token's transaction history on Blockscout.
- If the flag comes from a sell simulation: selling through a Uniswap v4 pool with a custom hook may fail in a simulator even though real sells succeed. Our test suite buys and then sells the entire balance through a plain third-party v4 router (`test_scanner_buyAndSellAllThroughThirdPartyRouter` in `contracts/test/Company.t.sol`).

## 3. Independent audit

`<audit link and summary, once available>`

We kindly ask you to re-review the contract and remove the flag(s). We're happy to provide anything else you need.
