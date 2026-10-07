// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SafeTransfer} from "./lib/SafeTransfer.sol";

interface ICompanyHook {
    function flush(address token) external;
    function feeRecipient() external view returns (address);
    function router() external view returns (address);
    function ethRouter() external view returns (address);
    function poolManager() external view returns (address);
    function IMD() external view returns (address);
}

/// @dev Chainlink AggregatorV3 (Robinhood Chain stock and USDG/USD feeds, 8 decimals).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title CompanyToken ($COMPANY)
/// @notice The Zero Person Billion Dollar Company. Fixed 1,000,000,000 supply, traded in a Uniswap v4 pool against IMD
///         through CompanyHook, which charges 4% of every swap: 1% protocol, 3% to $COMPANY holders pro rata. The
///         holder share is paid in six assets:
///           - 50% in IMD, credited at once;
///           - 10% each in NVDA, GOOGL, AAPL, GME and MSTR Robinhood stock tokens. That IMD waits in a per-stock
///             reserve until it is converted (IMD -> USDG -> stock, Uniswap v4 pools fixed at deployment), then
///             the stock bought is credited to holders.
///
///         Only wallets holding at least 100,000 $COMPANY earn (`MIN_HOLDING`); smaller balances earn nothing.
///         Rewards are claimed with `claim()`, which first converts waiting reserves into stocks (no keeper
///         needed; `convert()` does the same for anyone), then pays all six assets. A wallet is active when it claims, sends tokens, pulls tokens
///         itself, or receives tokens for the first time (buying alone does not count: claim at least weekly). Rewards
///         of a wallet inactive for more than 7 days expire, except what it earned during those last 7 days, and go
///         to the protocol address (the hook's `feeRecipient`).
///
///         Known limits of expiry (the same design was reviewed in IMD Swarm job cbe092d6, finding 1):
///           - "recent" rewards are estimated from the wallet's current earning weight, so tokens it is sent during
///             its last 7 days count as if they had earned for it in that window. A gift after a distribution can
///             delay the expiry of older rewards by at most 7 days, to nobody's gain (the sender keeps its own
///             rewards on those tokens);
///           - stock rewards are credited to whoever holds when the stock is bought (at a claim or `convert()`),
///             not when the fee was paid (audit 78c00339, finding 6). Conversions run at most a minute apart
///             whenever anyone claims, which keeps the waiting reserve small;
///           - stock already bought can't be moved if its token later blocks this contract (finding 7).
///
///         Stock tokens can block addresses. A payout that fails stays claimable (it is not lost), and the other
///         assets are still paid. When a stock can't be bought, that round's IMD for it is paid to holders as IMD.
/// @dev Dividends use the "magnified dividend per share" pattern once per asset: accrual is O(1) for every holder
///      on each distribution. The hook, the routers, the v4 PoolManager (which holds the pool's tokens), this
///      contract and burn addresses are system accounts and earn nothing. Ownership is renounced at deployment. No
///      function checks the owner; the only caller checks are technical (`unlockCallback`: the PoolManager;
///      `convertStock`: this contract; mid-unlock `distribute`: the hook).
contract CompanyToken is IUnlockCallback {
    using SafeTransfer for address;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidRecipient();
    error Overflow();
    error Reentrancy();
    error PermitExpired();
    error InvalidSignature();
    error NotEligible();
    error NotPoolManager();
    error NotSelf();
    error PriceOff();
    error BadFeed();
    error BadAsset();
    error BadAmount();
    error BadPool();
    error TooSoon();
    error Slippage();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RewardsDistributed(uint256 indexed asset, uint256 amount, uint256 eligibleSupply);
    event RewardClaimed(address indexed holder, uint256 indexed asset, uint256 amount);
    /// @notice A payout the asset refused (e.g. a blocked address); it stays claimable.
    event PayoutFailed(address indexed holder, uint256 indexed asset, uint256 amount);
    event RewardsRecycled(address indexed holder, uint256 indexed asset, uint256 amount);
    event Converted(uint256 indexed asset, uint256 imdIn, uint256 usdOut, uint256 stockOut);
    /// @notice A stock couldn't be bought this round, so its IMD was credited to holders as IMD instead.
    event ConversionFailed(uint256 indexed asset, uint256 imdAmount);

    uint256 public constant totalSupply = 1_000_000_000e18;
    uint8 public constant decimals = 18;
    /// @notice A wallet earns rewards only while it holds at least this much $COMPANY; below it, its weight is 0.
    uint256 public constant MIN_HOLDING = 100_000e18;
    /// @dev Distributions wait until some wallet holds at least MIN_HOLDING. Bounds per-share growth.
    uint256 public constant MIN_ELIGIBLE_SUPPLY = MIN_HOLDING;
    /// @notice Rewards of a wallet inactive for longer than this expire (except those earned within it).
    uint256 public constant INACTIVITY_PERIOD = 7 days;

    /// @notice Reward assets: 0 = IMD, 1..5 = NVDA, GOOGL, AAPL, GME, MSTR.
    uint256 public constant ASSETS = 6;
    uint256 public constant BPS = 10_000;
    /// @notice Share of each holder-fee distribution set aside for each stock; IMD gets the rest (50%).
    uint256 public constant STOCK_SHARE_BPS = 1_000;
    /// @notice One conversion round (run by `claim` or `convert`) spends at most 0.25% of the IMD/USDG pool's IMD
    ///         depth in total, shared by the five stocks. Sandwiching it then costs more in that pool's 0.9% fees
    ///         than it can move the price.
    uint256 public constant MAX_CONVERT_BPS = 25;
    /// @notice Fixed ceiling on one round, whatever the pool reads: the depth above is read in the same transaction,
    ///         and just-in-time liquidity can inflate it (audit 78c00339, finding 1). Sandwiching a round stays
    ///         unprofitable while the IMD/USDG pool's real depth exceeds about ROUND/0.9% (~2,200 IMD; ~19,750 at
    ///         launch).
    uint256 public constant MAX_ROUND_IMD = 20e18;
    /// @notice Minimum time between two conversions of the same stock. Every transaction in a block shares one
    ///         timestamp, so this allows one round per block at most: nobody can claim many times in one
    ///         transaction to sell more IMD at a price they pushed.
    uint256 public constant CONVERT_INTERVAL = 1 minutes;
    /// @notice Gas each stock's purchase gets. A fixed budget means a purchase fails only for a real reason (the
    ///         stock token or its pool refusing it), never because a caller sent a claim with too little gas.
    uint256 public constant CONVERT_GAS = 1_000_000;
    /// @notice A stock purchase must receive at least this close to what Chainlink's prices imply (USDG/USD and the
    ///         stock's /USD feed); otherwise the stock is skipped this round (audit f1d5def3, finding 1). Covers the
    ///         pool fee (up to 1%), price impact of a capped round and the feeds' 0.5% deviation threshold.
    uint256 public constant ORACLE_TOLERANCE_BPS = 300;
    /// @notice A feed older than this (equity feeds pause over weekends and holidays) holds that stock's rounds.
    uint256 public constant MAX_ORACLE_AGE = 4 days;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal constant Q96 = 2 ** 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable hook;
    address public immutable router;
    address public immutable ethRouter;
    address public immutable poolManager;
    /// @notice IMD: the pool's quote asset, reward asset 0.
    address public immutable quote;
    /// @notice USDG: the middle hop of every conversion.
    address public immutable usd;

    /// @notice Fee and tick spacing of a hookless Uniswap v4 pool; its currencies are implied.
    struct Pool {
        uint24 fee;
        int24 tickSpacing;
    }

    /// @notice Reward asset addresses, fixed at deployment (index 0 is IMD).
    address[ASSETS] public assets;
    /// @notice IMD/USDG pool used for the first hop of every conversion.
    Pool public imdUsdPool;
    /// @notice USDG/stock pool of each stock (index 0 unused).
    Pool[ASSETS] public stockPools;
    /// @notice Chainlink USD price feed of each stock (index 0 unused), fixed at deployment.
    address[ASSETS] public priceFeeds;
    /// @notice Chainlink USDG/USD feed.
    address public immutable usdFeed;
    /// @dev 10^decimals of USDG and of each stock, read at deployment (USDG 6, stock tokens 18).
    uint256 internal immutable _usdUnit;
    uint256[ASSETS] internal _unit;

    /// @notice Always the zero address: ownership is renounced in the constructor. The token has no function that
    ///         checks it (nothing an owner could do), and nothing can ever set it again.
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Sum of all earning weights (tokens held by non-excluded wallets with at least MIN_HOLDING).
    uint256 public eligibleSupply;

    uint256[ASSETS] public magnifiedRewardPerShare;
    mapping(uint256 asset => mapping(address => int256)) internal _corrections;
    mapping(uint256 asset => mapping(address => uint256)) public withdrawnRewards;
    /// @notice Amount of each asset held here that is owed to holders (distributed, not yet claimed or recycled).
    uint256[ASSETS] public owed;
    uint256[ASSETS] public totalDistributed;
    uint256[ASSETS] public totalRecycled;
    /// @notice Expired rewards the fee recipient couldn't receive yet (its address refused by that asset).
    uint256[ASSETS] public recycledHeld;

    /// @notice IMD set aside for each stock, waiting for `convert` (index 0 unused).
    uint256[ASSETS] public pendingConvert;
    /// @notice Last successful conversion of each stock (deployment time before the first).
    uint256[ASSETS] public lastConvert;

    /// @notice Last activity of each holder (unix seconds), see the contract notice.
    mapping(address => uint256) public lastActive;

    /// @dev magnifiedRewardPerShare of an asset after each distribution, by time: lets expiry compute what a
    ///      holder earned in the last 7 days (those rewards never expire).
    struct Checkpoint {
        uint64 time;
        uint192 mag;
    }

    mapping(uint256 asset => Checkpoint[]) internal _checkpoints;

    uint256 private _locked = 1;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    uint256 private immutable _initialChainId;
    bytes32 private immutable _initialDomainSeparator;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @param hook_ the CompanyHook; routers, PoolManager and IMD are read from it
    /// @param usd_ USDG
    /// @param imdUsdPool_ the IMD/USDG v4 pool (no hooks)
    /// @param stocks the five stock tokens, in asset order 1..5
    /// @param pools_ the USDG/stock v4 pool (no hooks) of each stock, same order
    /// @dev Every pool must already exist. The whole supply goes to the hook, whose one-time `openPool` locks it in
    ///      the pool.
    constructor(
        address hook_,
        address usd_,
        Pool memory imdUsdPool_,
        address[5] memory stocks,
        Pool[5] memory pools_,
        address usdFeed_,
        address[5] memory feeds_
    ) {
        ICompanyHook h = ICompanyHook(hook_);
        hook = hook_;
        router = h.router();
        ethRouter = h.ethRouter();
        poolManager = h.poolManager();
        quote = h.IMD();
        usd = usd_;
        _checkFeed(usdFeed_);
        usdFeed = usdFeed_;
        _usdUnit = 10 ** IPriceFeed(usd_).decimals();

        assets[0] = quote;
        imdUsdPool = imdUsdPool_;
        _checkPool(quote, usd_, imdUsdPool_);
        for (uint256 i; i < 5; i++) {
            address s = stocks[i];
            if (s == address(0) || s == quote || s == usd_ || s == address(this)) revert BadAsset();
            for (uint256 j; j < i; j++) {
                if (stocks[j] == s) revert BadAsset();
            }
            assets[i + 1] = s;
            stockPools[i + 1] = pools_[i];
            lastConvert[i + 1] = block.timestamp;
            _checkPool(usd_, s, pools_[i]);
            _checkFeed(feeds_[i]);
            priceFeeds[i + 1] = feeds_[i];
            _unit[i + 1] = 10 ** IPriceFeed(s).decimals();
        }

        balanceOf[hook_] = totalSupply;
        emit Transfer(address(0), hook_, totalSupply);
        // Standard renounce, as scanners expect: the deployer is recorded, then ownership goes to the zero address.
        // (A hard-coded `owner()` returning zero is read by GoPlus as a fake renounce, i.e. a "hidden owner".)
        emit OwnershipTransferred(address(0), msg.sender);
        emit OwnershipTransferred(msg.sender, address(0));
        _initialChainId = block.chainid;
        _initialDomainSeparator = _domainSeparator();
    }

    function name() public pure returns (string memory) {
        return "The Zero Person Billion Dollar Company";
    }

    function symbol() public pure returns (string memory) {
        return "COMPANY";
    }

    // ------------------------------------------------------------ EIP-2612

    /// @notice EIP-712 domain separator for `permit` (gasless approvals).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _initialChainId ? _initialDomainSeparator : _domainSeparator();
    }

    /// @notice Sets `spender`'s allowance from `holder`'s signature instead of an `approve` transaction.
    function permit(address holder, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonces[holder]++, deadline))
            )
        );
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != holder) revert InvalidSignature();
        allowance[holder][spender] = value;
        emit Approval(holder, spender, value);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---------------------------------------------------------------- ERC20

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Standard allowance for every spender: no address is exempt.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidRecipient();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        bool fromSystem = isSystemAccount(from);
        bool toSystem = isSystemAccount(to);
        uint256 fromWeightBefore = fromSystem ? 0 : _weight(bal);
        uint256 toWeightBefore = toSystem ? 0 : _weight(balanceOf[to]);
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;

        // Rewards stay with whoever held the tokens when they were earned, for every asset. Only the earning
        // weight (the balance, or 0 below MIN_HOLDING) changes, so each side is corrected by its weight change.
        if (!fromSystem) _reweigh(from, fromWeightBefore, _weight(balanceOf[from]));
        if (!toSystem) _reweigh(to, toWeightBefore, _weight(balanceOf[to]));

        // Activity (a zero-amount transferFrom needs no allowance, so it never counts). Sending is the holder's own
        // act. Receiving counts only when the recipient initiated it or for a first receipt. Tokens arriving from the
        // PoolManager don't count: anyone can move 1 wei out of it to any address for free (audit 78c00339,
        // finding 4), so a buy is not activity; claiming or sending is.
        if (amount != 0) {
            if (!fromSystem) lastActive[from] = block.timestamp;
            if (!toSystem && (msg.sender == to || lastActive[to] == 0)) lastActive[to] = block.timestamp;
        }

        emit Transfer(from, to, amount);
    }

    // ------------------------------------------------------------ Rewards

    /// @notice Earning weight of a holder: its balance once it holds at least MIN_HOLDING, else 0.
    function weightOf(address holder) public view returns (uint256) {
        return isSystemAccount(holder) ? 0 : _weight(balanceOf[holder]);
    }

    function _weight(uint256 balance) internal pure returns (uint256) {
        return balance >= MIN_HOLDING ? balance : 0;
    }

    /// @dev Applies a weight change: past rewards are kept as they were, future ones accrue on the new weight.
    function _reweigh(address holder, uint256 before, uint256 next) internal {
        if (before == next) return;
        for (uint256 a; a < ASSETS; a++) {
            uint256 mag = magnifiedRewardPerShare[a];
            if (mag == 0) continue;
            if (next > before) _corrections[a][holder] -= _toInt(mag * (next - before));
            else _corrections[a][holder] += _toInt(mag * (before - next));
        }
        if (next > before) eligibleSupply += next - before;
        else eligibleSupply -= before - next;
    }

    function isSystemAccount(address account) public view returns (bool) {
        return account == poolManager || account == hook || account == router || account == ethRouter
            || account == address(this) || account == address(0) || account == DEAD;
    }

    /// @notice Splits IMD received since the last call (holder fees): 50% is credited to holders at once, 10% is
    ///         added to each stock's conversion reserve.
    /// @dev Never reverts: trades and claims call it. While the PoolManager is unlocked its tokens can be
    ///      flash-borrowed and would count as held, so mid-unlock only the hook may distribute (as in PadToken v3).
    function distribute() public returns (uint256 amount) {
        if (msg.sender != hook && IPoolManager(poolManager).isUnlocked()) return 0;
        if (eligibleSupply < MIN_ELIGIBLE_SUPPLY) return 0;
        uint256 bal = quote.balanceOf(address(this));
        uint256 tracked = owed[0] + _pendingTotal() + recycledHeld[0];
        if (bal <= tracked) return 0;
        amount = bal - tracked;
        uint256 perStock = (amount * STOCK_SHARE_BPS) / BPS;
        for (uint256 a = 1; a < ASSETS; a++) {
            pendingConvert[a] += perStock;
        }
        _credit(0, amount - perStock * (ASSETS - 1));
    }

    /// @notice Credits holders with any balance of stock `asset` held here beyond what they are already owed
    ///         (bought by `convert`, donated, or from a rebase of the stock token).
    function distributeStock(uint256 asset) public returns (uint256 amount) {
        if (asset == 0 || asset >= ASSETS) revert BadAsset();
        if (IPoolManager(poolManager).isUnlocked()) return 0;
        if (eligibleSupply < MIN_ELIGIBLE_SUPPLY) return 0;
        uint256 bal = assets[asset].balanceOf(address(this));
        uint256 tracked = owed[asset] + recycledHeld[asset];
        if (bal <= tracked) return 0;
        amount = bal - tracked;
        _credit(asset, amount);
    }

    function _credit(uint256 asset, uint256 amount) internal {
        if (amount == 0) return;
        uint256 eligible = eligibleSupply;
        uint256 mag = magnifiedRewardPerShare[asset] + (amount * MAGNITUDE) / eligible;
        magnifiedRewardPerShare[asset] = mag;
        owed[asset] += amount;
        totalDistributed[asset] += amount;
        _checkpoint(asset, mag);
        emit RewardsDistributed(asset, amount, eligible);
    }

    function accumulativeRewardOf(address holder, uint256 asset) public view returns (uint256) {
        if (isSystemAccount(holder)) return 0;
        int256 mag = _toInt(magnifiedRewardPerShare[asset] * weightOf(holder)) + _corrections[asset][holder];
        return mag <= 0 ? 0 : uint256(mag) / MAGNITUDE;
    }

    function withdrawableRewardOf(address holder, uint256 asset) public view returns (uint256) {
        uint256 acc = accumulativeRewardOf(holder, asset);
        uint256 done = withdrawnRewards[asset][holder];
        return acc > done ? acc - done : 0;
    }

    /// @notice Withdrawable amount of every reward asset for `holder` (same order as `assets`).
    function rewardsOf(address holder) external view returns (uint256[ASSETS] memory amounts) {
        for (uint256 a; a < ASSETS; a++) {
            amounts[a] = withdrawableRewardOf(holder, a);
        }
    }

    function assetList() external view returns (address[ASSETS] memory) {
        return assets;
    }

    /// @notice Pulls in fees from swaps made through other routers, converts waiting reserves into stocks (see
    ///         `convert`), sends any expired part of the caller's rewards to the protocol address, pays out the rest
    ///         in all six assets, and resets their 7-day timer. An asset that refuses the payout is skipped and stays
    ///         claimable; a stock that fails to convert is skipped and tried again on a later claim.
    function claim() external nonReentrant returns (uint256[ASSETS] memory amounts) {
        ICompanyHook(hook).flush(address(this));
        _convertAll();
        if (!isSystemAccount(msg.sender)) {
            // Expiry is strict: rewards that expired before this claim go to the protocol, not to the claimer.
            // Computed before the claim resets the timer.
            _recycle(msg.sender);
            lastActive[msg.sender] = block.timestamp;
        }
        for (uint256 a; a < ASSETS; a++) {
            uint256 amount = withdrawableRewardOf(msg.sender, a);
            if (amount == 0) continue;
            withdrawnRewards[a][msg.sender] += amount;
            owed[a] -= amount;
            if (_tryTransfer(assets[a], msg.sender, amount)) {
                amounts[a] = amount;
                emit RewardClaimed(msg.sender, a, amount);
            } else {
                withdrawnRewards[a][msg.sender] -= amount;
                owed[a] += amount;
                emit PayoutFailed(msg.sender, a, amount);
            }
        }
    }

    // ------------------------------------------------------------ Expiry

    /// @notice Rewards of `holder` in `asset` that have expired: everything unclaimed except what it earned in the
    ///         last 7 days, once it has been inactive for more than 7 days. Zero while it is active.
    /// @dev Both boundaries are exclusive on the holder's side: a wallet is inactive only after more than 7 days,
    ///      and a reward distributed exactly 7 days ago still counts as recent.
    function expiredRewardsOf(address holder, uint256 asset) public view returns (uint256) {
        if (isSystemAccount(holder)) return 0;
        uint256 last = lastActive[holder];
        if (last == 0 || block.timestamp <= last + INACTIVITY_PERIOD) return 0;
        uint256 w = withdrawableRewardOf(holder, asset);
        if (w == 0) return 0;
        // Since `last` the weight can only have grown (every send records activity), so weight x (per-share
        // growth since the cutoff) is at least what it earned since the cutoff: "recent" can only be
        // over-estimated, in the holder's favour. Rounded up as well.
        uint256 magCut = magAt(asset, block.timestamp - INACTIVITY_PERIOD - 1);
        uint256 recent = FullMath.mulDivRoundingUp(magnifiedRewardPerShare[asset] - magCut, weightOf(holder), MAGNITUDE);
        return w > recent ? w - recent : 0;
    }

    /// @notice Sends `holder`'s expired rewards (all assets) to the protocol address (the hook's `feeRecipient`).
    ///         Callable by anyone; it can only ever move rewards that have expired, and only to that address.
    function recycle(address holder) public nonReentrant returns (uint256[ASSETS] memory expired) {
        if (isSystemAccount(holder)) revert NotEligible();
        expired = _recycle(holder);
    }

    function recycleMany(address[] calldata holders) external {
        for (uint256 i; i < holders.length; i++) {
            if (!isSystemAccount(holders[i])) recycle(holders[i]);
        }
    }

    function _recycle(address holder) internal returns (uint256[ASSETS] memory expired) {
        address to = ICompanyHook(hook).feeRecipient();
        for (uint256 a; a < ASSETS; a++) {
            uint256 amount = expiredRewardsOf(holder, a);
            if (amount == 0) continue;
            withdrawnRewards[a][holder] += amount;
            owed[a] -= amount;
            expired[a] = amount;
            totalRecycled[a] += amount;
            emit RewardsRecycled(holder, a, amount);
            // Expired rewards leave the holder either way. If the asset refuses the fee recipient (a stock token can
            // block it), they wait here for `sendRecycled` instead of going back to the holder (audit 78c00339,
            // finding 8).
            if (!_tryTransfer(assets[a], to, amount)) recycledHeld[a] += amount;
        }
    }

    /// @notice Sends expired rewards held for the fee recipient (see `recycledHeld`) once the asset accepts it, for
    ///         example after the hook owner points `feeRecipient` at an address the stock token allows. Anyone may
    ///         call it; it can only send to the current `feeRecipient`.
    function sendRecycled(uint256 asset) external nonReentrant returns (uint256 amount) {
        if (asset >= ASSETS) revert BadAsset();
        amount = recycledHeld[asset];
        if (amount == 0) return 0;
        recycledHeld[asset] = 0;
        if (!_tryTransfer(assets[asset], ICompanyHook(hook).feeRecipient(), amount)) {
            recycledHeld[asset] = amount;
            amount = 0;
        }
    }

    // ------------------------------------------------------------ Conversion

    /// @notice Converts each stock's waiting IMD into that stock (IMD -> USDG -> stock) and credits it to holders.
    ///         `claim` runs it first, so holders need no keeper; anyone may also call it. One round spends at most
    ///         `maxConvert()` IMD shared by the five stocks (larger reserves convert over later rounds), and each
    ///         stock converts at most once per `CONVERT_INTERVAL`, so no one can profit from sandwiching it. A stock
    ///         that isn't due or has nothing waiting is skipped. A stock that can't be bought (its token refuses this
    ///         contract, its pool can't fill the swap) has this round's IMD credited to holders as IMD instead.
    /// @return stockOut stock bought per asset this round (index 0 unused)
    function convert() external nonReentrant returns (uint256[ASSETS] memory stockOut) {
        stockOut = _convertAll();
    }

    function _convertAll() internal returns (uint256[ASSETS] memory stockOut) {
        // Inside someone else's unlock the swaps can't run (and the pool could be mid-manipulation): skip.
        if (IPoolManager(poolManager).isUnlocked()) return stockOut;
        uint256 cap = maxConvert() / (ASSETS - 1);
        for (uint256 a = 1; a < ASSETS; a++) {
            if (block.timestamp < lastConvert[a] + CONVERT_INTERVAL) continue;
            uint256 imdIn = pendingConvert[a];
            if (imdIn > cap) imdIn = cap;
            if (imdIn == 0) continue;
            uint256 poolLimit = stockRoundLimit(a);
            // No liquidity at the stock pool's price: a swap would cross to whatever position sits next, at its
            // price (audit f1d5def3, finding 2). Hand this round to holders as IMD without swapping.
            if (poolLimit == 0) {
                _fallBackToImd(a, imdIn);
                continue;
            }
            if (imdIn > poolLimit) imdIn = poolLimit;
            // A missing or stale price feed holds the stock until it updates (no fallback: value waits, not moves).
            if (!_feedsFresh(a)) continue;
            // Too little gas for a full CONVERT_GAS: skip the stock, never fall back, so a low-gas caller can't turn
            // stock into IMD and a claim never fails on it (audit f1d5def3, finding 3).
            if (gasleft() < (CONVERT_GAS * 64) / 63 + 50_000) continue;
            try this.convertStock{gas: CONVERT_GAS}(a, imdIn) returns (uint256 out) {
                stockOut[a] = out;
            } catch (bytes memory reason) {
                // Price away from Chainlink's: someone may be moving the pool. Skip, try again next round.
                if (reason.length >= 4 && bytes4(reason) == PriceOff.selector) continue;
                _fallBackToImd(a, imdIn);
            }
        }
    }

    /// @dev This round's IMD for stock `asset` couldn't buy it: credit it to holders as IMD. Only this round's
    ///      amount moves, so one failure (even one an outside party causes) changes at most one round's capped
    ///      amount; a stock that keeps failing hands its reserve over round by round.
    function _fallBackToImd(uint256 asset, uint256 imdIn) internal {
        if (eligibleSupply < MIN_ELIGIBLE_SUPPLY) return;
        pendingConvert[asset] -= imdIn;
        lastConvert[asset] = block.timestamp;
        _credit(0, imdIn);
        emit ConversionFailed(asset, imdIn);
    }

    /// @notice One stock's conversion. Only this contract calls it (from `claim` / `convert`), as a separate call
    ///         so a stock that fails is undone and skipped without affecting the others or the claim.
    function convertStock(uint256 asset, uint256 imdIn) external returns (uint256 stockOut) {
        if (msg.sender != address(this)) revert NotSelf();
        lastConvert[asset] = block.timestamp;
        pendingConvert[asset] -= imdIn;

        address stock = assets[asset];
        uint256 before = stock.balanceOf(address(this));
        uint256 usdOut = abi.decode(IPoolManager(poolManager).unlock(abi.encode(asset, imdIn)), (uint256));
        stockOut = stock.balanceOf(address(this)) - before;
        if (stockOut == 0) revert Slippage();
        emit Converted(asset, imdIn, usdOut, stockOut);
        distributeStock(asset);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert NotPoolManager();
        (uint256 asset, uint256 imdIn) = abi.decode(data, (uint256, uint256));
        IPoolManager pm = IPoolManager(poolManager);

        uint256 usdOut = _swapExactIn(_key(quote, usd, imdUsdPool), quote, imdIn);
        uint256 stockOut = _swapExactIn(_key(usd, assets[asset], stockPools[asset]), usd, usdOut);
        if (stockOut < minStockOut(asset, usdOut)) revert PriceOff();

        pm.sync(Currency.wrap(quote));
        quote.transferOut(poolManager, imdIn);
        pm.settle();
        pm.take(Currency.wrap(assets[asset]), address(this), stockOut);
        return abi.encode(usdOut);
    }

    /// @dev Swaps all of `amountIn` of `tokenIn`; returns the output owed to this contract.
    function _swapExactIn(PoolKey memory key, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert BadAmount();
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        BalanceDelta delta = IPoolManager(poolManager)
            .swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        (int128 dIn, int128 dOut) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // A pool too thin to take the whole input would leave a debt the unlock can't settle: fail clearly instead.
        if (uint256(int256(-dIn)) != amountIn || dOut <= 0) revert Slippage();
        out = uint256(int256(dOut));
    }

    /// @notice Most IMD one conversion round spends, all stocks together: 0.25% of the IMD/USDG pool's (virtual)
    ///         IMD reserve at the current price.
    function maxConvert() public view returns (uint256) {
        PoolKey memory key = _key(quote, usd, imdUsdPool);
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(id);
        if (sqrtP == 0) return 0;
        uint256 liquidity = IPoolManager(poolManager).getLiquidity(id);
        uint256 imdDepth = Currency.unwrap(key.currency0) == quote
            ? FullMath.mulDiv(liquidity, Q96, sqrtP)  // IMD is currency0: x = L / sqrtP
            : FullMath.mulDiv(liquidity, sqrtP, Q96); // IMD is currency1: y = L * sqrtP
        uint256 cap = (imdDepth * MAX_CONVERT_BPS) / BPS;
        return cap > MAX_ROUND_IMD ? MAX_ROUND_IMD : cap;
    }

    /// @notice Most IMD one round may spend on stock `asset`, from its own USDG/stock pool (audit 78c00339,
    ///         finding 2): half the pool fee times its virtual USDG depth, priced in IMD at the IMD/USDG pool. A
    ///         sandwich of that hop then costs more in the pool's fee than it can move the price. Zero for a pool
    ///         with no liquidity (the round then falls back to IMD).
    function stockRoundLimit(uint256 asset) public view returns (uint256) {
        if (asset == 0 || asset >= ASSETS) revert BadAsset();
        Pool memory p = stockPools[asset];
        PoolKey memory sk = _key(usd, assets[asset], p);
        (uint160 sp,,,) = IPoolManager(poolManager).getSlot0(sk.toId());
        uint256 liquidity = IPoolManager(poolManager).getLiquidity(sk.toId());
        if (sp == 0 || liquidity == 0) return 0;
        uint256 usdDepth = Currency.unwrap(sk.currency0) == usd
            ? FullMath.mulDiv(liquidity, Q96, sp)  // USDG is currency0
            : FullMath.mulDiv(liquidity, sp, Q96); // USDG is currency1
        uint256 usdLimit = FullMath.mulDiv(usdDepth, p.fee, 2_000_000); // fee is in millionths
        PoolKey memory ik = _key(quote, usd, imdUsdPool);
        (uint160 ip,,,) = IPoolManager(poolManager).getSlot0(ik.toId());
        if (ip == 0) return 0;
        // price = currency1 per currency0 = (ip / 2^96)^2
        return Currency.unwrap(ik.currency0) == quote
            ? FullMath.mulDiv(FullMath.mulDiv(usdLimit, Q96, ip), Q96, ip)  // USDG per IMD: IMD = USDG / price
            : FullMath.mulDiv(FullMath.mulDiv(usdLimit, ip, Q96), ip, Q96); // IMD per USDG: IMD = USDG * price
    }

    /// @notice Least stock a purchase with `usdIn` USDG (6 decimals) must receive: its value at Chainlink's USDG/USD
    ///         and stock/USD prices, less ORACLE_TOLERANCE_BPS. Reverts PriceOff when a feed is unusable.
    function minStockOut(uint256 asset, uint256 usdIn) public view returns (uint256) {
        if (asset == 0 || asset >= ASSETS) revert BadAsset();
        (bool okU, uint256 usdgUsd) = _readFeed(usdFeed);
        (bool okS, uint256 stockUsd) = _readFeed(priceFeeds[asset]);
        if (!okU || !okS) revert PriceOff();
        // both feeds have 8 decimals: stock = usdIn x (USDG/USD) / (stock/USD), rescaled from USDG to stock units
        uint256 fair = FullMath.mulDiv(usdIn * usdgUsd, _unit[asset], stockUsd * _usdUnit);
        return (fair * (BPS - ORACLE_TOLERANCE_BPS)) / BPS;
    }

    function _feedsFresh(uint256 asset) internal view returns (bool) {
        (bool okU,) = _readFeed(usdFeed);
        (bool okS,) = _readFeed(priceFeeds[asset]);
        return okU && okS;
    }

    /// @dev Latest answer if it is positive and no older than MAX_ORACLE_AGE; never reverts.
    function _readFeed(address feed) internal view returns (bool ok, uint256 price) {
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeWithSelector(IPriceFeed.latestRoundData.selector));
        if (!success || ret.length < 160) return (false, 0);
        (, int256 answer,, uint256 updatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || updatedAt == 0 || updatedAt + MAX_ORACLE_AGE < block.timestamp) return (false, 0);
        return (true, uint256(answer));
    }

    function _checkFeed(address feed) internal view {
        if (feed.code.length == 0 || IPriceFeed(feed).decimals() != 8) revert BadFeed();
    }

    /// @notice v4 pool keys of the conversion route for stock `asset`: IMD/USDG, then USDG/stock.
    function routeOf(uint256 asset) external view returns (PoolKey memory first, PoolKey memory second) {
        if (asset == 0 || asset >= ASSETS) revert BadAsset();
        first = _key(quote, usd, imdUsdPool);
        second = _key(usd, assets[asset], stockPools[asset]);
    }

    function _key(address a, address b, Pool memory p) internal pure returns (PoolKey memory) {
        (address c0, address c1) = uint160(a) < uint160(b) ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _checkPool(address a, address b, Pool memory p) internal view {
        (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(_key(a, b, p).toId());
        if (sqrtP == 0) revert BadPool();
    }

    function _pendingTotal() internal view returns (uint256 total) {
        for (uint256 a = 1; a < ASSETS; a++) {
            total += pendingConvert[a];
        }
    }

    // ------------------------------------------------------------ Checkpoints

    function checkpointCount(uint256 asset) external view returns (uint256) {
        return _checkpoints[asset].length;
    }

    /// @notice magnifiedRewardPerShare of `asset` as of time `t` (after every distribution at or before `t`).
    function magAt(uint256 asset, uint256 t) public view returns (uint256) {
        Checkpoint[] storage cps = _checkpoints[asset];
        uint256 hi = cps.length;
        uint256 lo;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].time <= t) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : cps[lo - 1].mag;
    }

    function _checkpoint(uint256 asset, uint256 mag) internal {
        if (mag > type(uint192).max) return; // unreachable in practice; never block a distribution
        Checkpoint[] storage cps = _checkpoints[asset];
        uint256 n = cps.length;
        if (n != 0 && cps[n - 1].time == block.timestamp) cps[n - 1].mag = uint192(mag);
        else cps.push(Checkpoint(uint64(block.timestamp), uint192(mag)));
    }

    // ------------------------------------------------------------ Helpers

    /// @dev ERC20 transfer that reports failure instead of reverting (stock tokens can refuse blocked addresses).
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert Overflow();
        return int256(x);
    }
}
