# IMDINDEX: The Zero Person Billion Dollar Company ($COMPANY)

**Website: [zeropersoncompany.fun](https://www.zeropersoncompany.fun)**

A fixed-supply token on Robinhood Chain (chain ID 4663), traded in a Uniswap v4 pool against **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`). Every trade pays a 4% fee. 3% goes to holders, and is paid not only in IMD but also in **AI and tech stock tokens**:

| Reward asset | Share of the holder fee | Token |
| --- | --- | --- |
| IMD | 50% | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| NVDA (NVIDIA) | 10% | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| GOOGL (Alphabet) | 10% | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` |
| AAPL (Apple) | 10% | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| GME (GameStop) | 10% | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` |
| MSTR (Strategy) | 10% | `0xec262a75e413fAfD0dF80480274532C79D42da09` |

The stocks are Robinhood Stock Tokens. Their addresses were checked on-chain on 2026-10-07: each one's symbol and name, and that all of them use the same official Robinhood token beacon (`0xe10b…1b00`).

**Status: not deployed, not audited.**

## How it works

- **Supply and pool:** 1,000,000,000 $COMPANY, all of it single-sided liquidity in one IMD-paired Uniswap v4 pool. `CompanyHook` owns that liquidity and has no function to remove it, so it is locked forever. The starting market cap is about $3,000, set in IMD on deploy day (default 306 IMD, at IMD ≈ $9.80 on 2026-10-07). The hook blocks anyone from creating other pools with it or adding liquidity.
- **Fee: 4% of the IMD side of every swap in the $COMPANY pool**, whichever router sends it: our routers, the Uniswap app, or an aggregator. (Like any token, $COMPANY could also be traded in a separate pool someone else creates; swaps there pay no fee. All the locked liquidity is in this pool.)
  - 1% goes to the protocol. Anyone can call `collectProtocolFees(IMD)` to send it to `0x8F5A29c82e8285Db3B2af8D0caF5404b0f9ce834`.
  - 3% goes to holders, split by `CompanyToken.distribute()`:
    - **50% in IMD**, credited to holders pro rata straight away.
    - **10% for each of the 5 stocks.** That IMD waits in a reserve per stock until it is converted.
- **Conversion happens when people claim:** every `claim()` first converts the waiting reserves. It swaps them along IMD → USDG → stock, through Uniswap v4 pools fixed at deployment, and credits the stock bought to holders pro rata, including the person claiming. No keeper or bot is needed. Anyone can also call `convert()` to do the same without claiming.
  - Limits: one round spends at most `maxConvert()` IMD: 0.25% of the IMD/USDG pool's IMD depth, and never more than a fixed **20 IMD** (`MAX_ROUND_IMD`), shared by the 5 stocks. The fixed ceiling matters because the depth is read in the same transaction and could be inflated with just-in-time liquidity. Each stock's part is also limited by its own USDG/stock pool (`stockRoundLimit`: half the pool fee times its depth). At these sizes, sandwiching either swap costs more in pool fees than it can gain. Each stock converts at most once a minute, so claiming many times in one transaction can't sell more IMD at a manipulated price. Larger reserves convert over later claims.
  - **Chainlink price check.** Every stock purchase must receive at least 97% (after the pool's own fee) of what Chainlink's prices imply (the stock's `/USD` feed and USDG/USD on Robinhood Chain). If the pool's price has been pushed away from Chainlink's, or a feed is more than 4 days old (weekends, holidays), that stock is **skipped** this round (not converted to IMD) and tried again next round. The IMD → USDG step is checked too: it must get at least 90% (after the pool fee) of IMD's value via the IMD/ETH pool and Chainlink ETH/USD, so nothing is ever sold at a made-up price. If a stock's reserve waits 30 days without a real purchase, and its purchases have been failing for at least a day, for any reason (dead feed, empty pool, prices stuck apart), its rounds are paid to holders as IMD in full 4 IMD rounds. A quiet month on its own never does this. No keeper is needed. For the stock step, a price manipulated inside a transaction can't pass this, however thin the pool, because Chainlink is the reference. Feeds: NVDA, GOOGL, AAPL, GME, MSTR, USDG and ETH, listed in `CompanyConfig.sol`.
  - **A stock that can't be bought is paid as IMD instead.** If a purchase fails (its token refuses this contract, or its pool can't fill the swap), that round's IMD for the stock is credited to holders as IMD in the same claim, and the claimer receives their share at once. Each purchase runs with a fixed gas budget (`CONVERT_GAS`, 1,000,000; real purchases use about 250,000–300,000), and a claim with too little gas left simply skips the stock purchases (it still pays out), so nobody can force purchases to fail to turn stock rewards into IMD. The website sends claims with a high gas limit so purchases run; unused gas isn't charged.
- **Minimum holding: 100,000 $COMPANY.** Only wallets holding at least 100,000 earn rewards. A wallet earns from the moment it reaches the minimum, never retroactively, and keeps what it earned if it drops below.
- **Claiming:** `claim()` pays all 6 assets in one transaction. Rewards accrue automatically for every holder, at constant (O(1)) cost, and each holder withdraws them. Because each claim also runs the swaps, it costs more gas than a plain claim.
- **Expiry (7 days):** **if a wallet goes more than 7 days without claiming, buying, selling or sending, its unclaimed rewards older than 7 days expire.** A buy counts when it is a real swap in the $COMPANY pool: the hook records the buyer (the user our routers report, otherwise the transaction's signer), so nobody can keep someone else's wallet active for free. A smart-contract wallet buying through another app is credited to its signer, not to itself: such wallets should claim, sell or send to stay active, or buy through the website. A wallet that comes back after more than 7 days (by claiming, buying, selling or sending) first gives up what has already expired. When a wallet has been inactive for more than 7 days, its unclaimed rewards in every asset expire, except what it earned in the last 7 days. Anyone can call `recycle(holder)` to send them to the protocol address, and `claim()` does this first for the caller. Known limits: tokens a wallet is sent during its last 7 days count toward its "recent" rewards, so a gift can delay the expiry of older rewards by up to 7 days (IMD Swarm cbe092d6 finding 1 on the same design). If a stock token refuses the fee address, expired stock is held for the protocol (`recycledHeld`) and sent later with `sendRecycled`; it never goes back to the claimer.
- **Blocked addresses:** stock tokens enforce a blocklist. If a payout is refused, the wallet keeps it as claimable rewards and the other assets are still paid. A stock that can't be bought is paid to holders as IMD, round by round.
- **No owner on the token:** ownership is renounced in the constructor, so `owner()` is `0x0`. No token function is restricted to an owner, and none can change balances, fees or transfers for anyone. The only caller checks are technical: `unlockCallback` accepts only the Uniswap PoolManager, `convertStock` only the token itself, and `markActive` only the hook (it records a buyer's activity and can never change a balance). The hook's owner can do only two things: open the pool once, and change the protocol fee recipient.
- **Flash-borrow guard:** rewards are never distributed while someone else has the Uniswap PoolManager unlocked. Pool tokens borrowed through v4 flash accounting therefore can't be counted as held. Conversion is skipped inside another caller's unlock too.

## Contracts

| Contract | Role |
| --- | --- |
| `src/CompanyHook.sol` | Owns the pool and is its v4 hook: the 4% fee and the 1%/3% split, locked liquidity, a one-time `openPool`. |
| `src/CompanyToken.sol` | $COMPANY: ERC-20 with EIP-2612 `permit`, rewards in 6 assets, 7-day expiry, and the capped stock conversion run by `claim()`. |
| `src/CompanyRouter.sol`, `src/CompanyEthRouter.sol` | Buy and sell with IMD, or with ETH through the IMD/ETH pool. Deployed by the hook. |

Conversion route (all pools hookless, ids checked against Uniswap's PositionManager and StateView):

| Pool | v4 pool id | Fee |
| --- | --- | --- |
| IMD/USDG | `0xaf5bcd88bb2b6084ca18319385b61fcbe17ec579032074861004f2668168406f` | 0.9% |
| USDG/NVDA | `0x6444a8e0b267406a15db74ca00c4a24bdfa81ed3180f5b6d0851f8ed6f4f29c5` | 0.01% |
| GOOGL/USDG | `0xd4ecb79fdc521d7725d22b33ed43cb4e47aa96bfad76aa29577e3151f723ac5e` | 0.3% |
| USDG/AAPL | `0xc748f4671a867db48b552f6b7650bf3255e05f80f00e3f7aad1b17ccb7898fdb` | 0.3% |
| GME/USDG | `0x3d436b4fdc532c61a0bf15d6cae80a66eb8f28ee9daec34dbec4b5bc9964063b` | 1% |
| USDG/MSTR | `0x319bac87e616a89e241c10aeb8afd4892a852cdd8b373cd9765ecddc40b87cfe` | 0.25% |

Uniswap v4 on Robinhood Chain: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. USDG: `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`.

## Setup

Needs [Foundry](https://book.getfoundry.sh/getting-started/installation). Dependencies (forge-std and Uniswap v4-core) are git submodules:

```bash
git clone --recursive https://github.com/imdmaxi/IMDINDEX.git
cd IMDINDEX/contracts
forge build
```

## Test

```bash
cd contracts
forge test                                                         # 65 unit, attack and fuzz tests on a real v4 PoolManager
FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest -vv   # live mainnet state: real IMD, USDG, stocks and pools
```

The tests cover:
- the fee split
- the 100,000 $COMPANY minimum: small wallets earn nothing, crossing it starts earning, dropping below keeps what was earned
- conversion: run by `claim()`, the cap shared by the five stocks, at most one round per minute even with many claims in one block, and all five stocks
- pro-rata payouts and transfers
- blocked holders and blocked stocks, and the IMD fallback when a stock can't be bought
- the Chainlink price check (manipulated, drifted or stale prices skip a stock) and every audit finding's reproduction
- expiry: inactive wallets, strict claims, gifts versus buys
- the flash-borrow guard
- `permit`
- a fuzzed solvency check: every asset stays fully backed, and what holders can withdraw never exceeds what is owed

## Website

`web/index.html` is a single-page site with no build step: Home, Swap (buy and sell with IMD or ETH), Portfolio (claimable rewards and a Claim button) and Docs. It reads live stock prices from the Robinhood Chain pools. Until the contracts are deployed it shows "pre-launch" states and a clearly labelled example wallet.

After deploying, copy `token`, `hook`, `router` and `ethRouter` from `contracts/deployments/robinhood.json` into `CONFIG` at the top of the script in `web/index.html`. To host it, deploy the `web/` folder to Vercel; `vercel.json` sets the security headers.

## Deploy

```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --interactive
```

The script mines the hook's CREATE2 salt (address flags `0x28CC`), deploys the hook and the token, opens the pool if the broadcasting account is the owner, and writes `deployments/robinhood.json`. Then publish the source:

```bash
./script/verify.sh
``` Optional environment variables: `OWNER`, `START_MCAP` (IMD in wei, default `306e18`, about $3,000 at IMD $9.80), `SALT_START`, `RECORD`.

## Security scanners

Earlier tokens built on a similar design were flagged by GoPlus and Quick Intel. Each cause was checked against those live tokens on 2026-10-07, and $COMPANY avoids every one:

| Flag seen before | Cause | $COMPANY |
| --- | --- | --- |
| GoPlus **honeypot** / **owner can change balance** | v1 token let its router move tokens without an allowance | Standard ERC-20 `transferFrom` for every spender, no exemptions. A test buys and then sells the whole balance through a plain third-party router. |
| GoPlus **hidden owner** | `owner()` hard-coded to return `0x0`. Every earlier token that had it is flagged; the one without it is not | A stored `owner`, renounced in the constructor with the standard `OwnershipTransferred` events. A test checks both events and `owner() == 0x0`. |
| **Owner not renounced** | No owner at all, so scanners can't confirm a renounce | Same fix: `owner()` reads `0x0` from storage after a real renounce. |
| Quick Intel **suspicious function** | v1's router exemption inside `transferFrom` | No function restricted to an owner or a special address can change balances, fees or transfers. `markActive`, which only the hook can call, changes nothing but a buyer's expiry timer (and moves already-expired rewards to the protocol). |
| **Not open source** | Unverified contracts | `script/verify.sh` publishes all four contracts to Sourcify and Blockscout right after deployment. |

The token also has no mint, burn, pause, blacklist, max-transaction, cooldown, proxy, `selfdestruct`, `delegatecall` or `tx.origin` code, and wallet-to-wallet transfers carry no tax. The 4% fee applies only to pool swaps, so scanners report it as a 4% buy and sell tax.

Scanners can only be checked after deployment. Before announcing, deploy, run `script/verify.sh`, and read the GoPlus result it prints. GoPlus's sell simulation can still report a false honeypot for tokens in a Uniswap v4 pool with a custom hook, as it did for an earlier token before a manual review cleared it. If any flag appears, send the review request in [`docs/scanner-review-request.md`](docs/scanner-review-request.md).

## Known risks

- **Stock token compliance.** Robinhood stock tokens are not offered to US persons. They enforce a per-address blocklist, and Robinhood Chain also filters transactions at the sequencer. If Robinhood blocks the token contract, that stock can't be bought, and its share is paid to holders as IMD instead. If Robinhood blocks a holder, that holder can't receive that stock. The fork test checks the token contracts, but not sequencer-level filtering.
- **Regulatory.** A token whose holders receive shares of a fee paid in tokenized equities may be treated as a security in some jurisdictions. Get legal advice before launch.
- **Fixed routes.** The conversion pools can't be changed after deployment. If liquidity leaves them, rounds shrink with the pool, and a pool with no liquidity at its price has that round paid to holders as IMD.
- **Conversion pricing.** Every purchase has two minimums: the stock step must get at least 97% of the Chainlink-implied amount, and the IMD → USDG step at least 90% of IMD's value via the IMD/ETH pool and Chainlink ETH/USD (both after the swap fee actually charged, including Uniswap's 0.1% protocol fee where it is on). The IMD reference is the IMD/ETH pool's price in the same transaction, so it is only as strong as that pool is deep. Within those tolerances, the 20 IMD round ceiling, the per-stock pool limits and the 1-minute spacing keep sandwiching unprofitable while the IMD/USDG pool holds more than about 2,200 IMD of depth (about 8,550 in range on 2026-10-07).
- **Stock rewards follow holders at purchase time.** Stocks are credited to whoever holds when they are bought (at a claim or `convert()`), not when the fee was paid. Conversions run at most a minute apart whenever anyone claims, which keeps the waiting amount small.
- **Partial fills.** Swaps through other apps that set a price limit must fill completely; a partial fill is rejected (`PartialFill`) instead of overpaying the fee.
- **Conversion pace.** Stocks are bought only when someone claims or calls `convert()`, one capped round per stock per minute.
- **IMD fallback.** Only one round's capped amount moves to IMD per failed purchase. Someone able to make a purchase fail on purpose (for example, a liquidity provider who pulls liquidity from a stock's pool in the same transaction) can turn that round's stock share into IMD. Holders still receive the full value, in IMD.
- **Stock corporate actions.** Extra stock balance (from rebases or donations) is credited with `distributeStock`. A reverse split that reduces this contract's balance would leave the last claimers short.
- **Dividend sniping.** Someone can buy just before a big trade to catch part of its holder fee, then sell. They pay 4% on each side, so it only pays off against trades much larger than their own position.
- **Late flushes for other routers.** Fees from swaps through other routers (the Uniswap app, aggregators) reach holders at the next CompanyRouter trade or claim, so that trader can share in their own fee.
- **Launch sniping.** Bots can buy in the launch block.
- **Not audited.** Get an independent audit before significant value flows through it.
