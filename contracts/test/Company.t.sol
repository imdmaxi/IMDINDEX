// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {CompanyHook} from "../src/CompanyHook.sol";
import {CompanyToken} from "../src/CompanyToken.sol";
import {CompanyRouter} from "../src/CompanyRouter.sol";
import {CompanyEthRouter} from "../src/CompanyEthRouter.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockERC20, MockStock, MockFeed} from "./Mocks.sol";

/// @notice Borrows the pool's $COMPANY inside an unlock, then tries to distribute, convert or claim with it.
/// @notice Audit 986abba2 finding 2: a contract wallet that buys through a plain router and claims in one call.
contract BatchWallet {
    function buyAndClaim(PoolSwapTest r, PoolKey memory k, bool zeroForOne, int256 amount, CompanyToken t)
        external
        returns (uint256[6] memory paid)
    {
        r.swap(
            k,
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        if (address(t) != address(0)) paid = t.claim();
    }

    function approve(address token, address spender) external {
        MockERC20(token).approve(spender, type(uint256).max);
    }
}

/// @notice Audit 882666b4 findings 1 and 2: borrows the pool's $COMPANY into `victim` inside an unlock, then has
///         the victim "send" (mode 1) or makes a dust buy for it (mode 2, tx.origin = victim), then repays.
contract FlashReviver is IUnlockCallback {
    IPoolManager immutable pm;
    CompanyToken immutable t;
    CompanyHook immutable h;
    address immutable imdToken;
    address victim;
    uint8 mode;

    constructor(IPoolManager pm_, CompanyToken t_, CompanyHook h_, address imd_) {
        pm = pm_;
        t = t_;
        h = h_;
        imdToken = imd_;
    }

    function run(address v, uint8 m) external {
        victim = v;
        mode = m;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        Currency company = Currency.wrap(address(t));
        uint256 borrowed = t.balanceOf(address(pm));
        pm.take(company, victim, borrowed);
        uint256 bought;
        if (mode == 2) {
            PoolKey memory k = h.poolKey(address(t));
            bool imdIs0 = Currency.unwrap(k.currency0) == imdToken;
            BalanceDelta d = pm.swap(
                k, SwapParams(imdIs0, -1e15, imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), ""
            );
            int128 out = imdIs0 ? d.amount1() : d.amount0();
            bought = uint256(int256(out));
            pm.sync(Currency.wrap(imdToken));
            MockERC20(imdToken).transfer(address(pm), 1e15);
            pm.settle();
        }
        // repay the borrowed tokens from the victim's wallet (a send by the victim's allowance)
        pm.sync(company);
        t.transferFrom(victim, address(pm), borrowed);
        pm.settle();
        if (bought != 0) pm.take(company, victim, bought);
        return "";
    }
}

/// @notice Audit finding 4: moves 1 wei of $COMPANY out of the PoolManager to `victim`, repaid from its own balance.
contract TimerPinger is IUnlockCallback {
    IPoolManager immutable pm;
    CompanyToken immutable t;
    address victim;

    constructor(IPoolManager pm_, CompanyToken t_) {
        pm = pm_;
        t = t_;
    }

    function ping(address v) external {
        victim = v;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.take(Currency.wrap(address(t)), victim, 1);
        pm.sync(Currency.wrap(address(t)));
        t.transfer(address(pm), 1);
        pm.settle();
        return "";
    }
}

contract FlashHolder is IUnlockCallback {
    IPoolManager immutable pm;
    CompanyToken immutable t;
    uint8 mode;

    constructor(IPoolManager pm_, CompanyToken t_) {
        pm = pm_;
        t = t_;
    }

    function run(uint8 mode_) external {
        mode = mode_;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        uint256 borrowed = t.balanceOf(address(pm));
        pm.take(Currency.wrap(address(t)), address(this), borrowed);
        if (mode == 1) t.distribute();
        else if (mode == 2) t.distributeStock(1);
        else if (mode == 3) t.convert();
        else t.claim();
        pm.sync(Currency.wrap(address(t)));
        t.transfer(address(pm), borrowed);
        pm.settle();
        return "";
    }
}

contract CompanyTest is Test {
    using StateLibrary for PoolManager;

    address constant FEE_RECIPIENT = 0x8F5A29c82e8285Db3B2af8D0caF5404b0f9ce834;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant START_MCAP = 306e18;
    int24 constant FULL_90 = 887220;
    int24 constant FULL_60 = 887220;
    int24 constant FULL_100 = 887200;

    PoolManager pm;
    MockERC20 imd;
    MockERC20 usdg;
    MockStock[5] stocks;
    MockFeed usdFeed;
    MockFeed ethFeed;
    MockFeed[5] feeds;
    CompanyHook hook;
    CompanyToken token;
    CompanyRouter router;
    CompanyEthRouter ethRouter;
    PoolSwapTest extRouter;
    PoolModifyLiquidityTest lp;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new MockERC20("Identity.md", "IMD");
        usdg = new MockERC20("Global Dollar", "USDG");
        string[5] memory names = ["NVDA", "GOOGL", "AAPL", "GME", "MSTR"];
        // all test pools trade 1:1 with USDG, so every feed reads $1
        usdFeed = new MockFeed(1e8);
        ethFeed = new MockFeed(1e8); // the test IMD/ETH pool is 1:1, so ETH = IMD = $1
        for (uint256 i; i < 5; i++) {
            stocks[i] = new MockStock(names[i]);
            feeds[i] = new MockFeed(1e8);
        }
        extRouter = new PoolSwapTest(pm);
        lp = new PoolModifyLiquidityTest(pm);
        vm.deal(address(this), 1_000_000 ether);
        imd.mint(address(this), 10_000_000e18);
        usdg.mint(address(this), 10_000_000e18);
        imd.approve(address(lp), type(uint256).max);
        usdg.approve(address(lp), type(uint256).max);

        // IMD/ETH (for the ETH router), 1:1.
        PoolKey memory imdEth =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 100, IHooks(address(0)));
        pm.initialize(imdEth, TickMath.getSqrtPriceAtTick(0));
        lp.modifyLiquidity{value: 20_000 ether}(imdEth, ModifyLiquidityParams(-FULL_100, FULL_100, 10_000e18, 0), "");

        // IMD/USDG at 1:1 with 10,000 of virtual depth: the conversion cap reads it (0.25% = 25 IMD).
        PoolKey memory imdUsd = _key(address(imd), address(usdg), 9000, 90);
        pm.initialize(imdUsd, TickMath.getSqrtPriceAtTick(0));
        lp.modifyLiquidity(imdUsd, ModifyLiquidityParams(-FULL_90, FULL_90, 10_000e18, 0), "");

        // USDG/stock pools, 1:1, deep.
        CompanyToken.Pool[5] memory pools;
        address[5] memory stockAddrs;
        for (uint256 i; i < 5; i++) {
            stocks[i].mint(address(this), 10_000_000e18);
            stocks[i].approve(address(lp), type(uint256).max);
            PoolKey memory k = _key(address(usdg), address(stocks[i]), 3000, 60);
            pm.initialize(k, TickMath.getSqrtPriceAtTick(0));
            lp.modifyLiquidity(k, ModifyLiquidityParams(-FULL_60, FULL_60, 1_000_000e18, 0), "");
            pools[i] = CompanyToken.Pool(3000, 60);
            stockAddrs[i] = address(stocks[i]);
        }

        bytes memory initCode = abi.encodePacked(
            type(CompanyHook).creationCode,
            abi.encode(
                pm,
                address(imd),
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(START_MCAP, SUPPLY),
                CompanyHook.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), _flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        hook = CompanyHook(payable(deployed));
        router = CompanyRouter(payable(hook.router()));
        ethRouter = CompanyEthRouter(payable(hook.ethRouter()));

        token =
            new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), stockAddrs, pools, _oracles());
        vm.prank(owner);
        hook.openPool(address(token));

        address[4] memory users = [alice, bob, carol, address(this)];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            imd.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            imd.approve(address(router), type(uint256).max);
            imd.approve(address(extRouter), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    receive() external payable {}

    function _flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    function _feedAddrs() internal view returns (address[5] memory f) {
        for (uint256 i; i < 5; i++) {
            f[i] = address(feeds[i]);
        }
    }

    function _oracles() internal view returns (CompanyToken.Oracles memory o) {
        o.usdFeed = address(usdFeed);
        o.ethUsdFeed = address(ethFeed);
        o.imdEthPool = CompanyToken.Pool(10_000, 100);
        o.stockFeeds = _feedAddrs();
    }

    function _key(address a, address b, uint24 fee, int24 ts) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, ts, IHooks(address(0)));
    }

    function _buy(address who, uint256 imdIn) internal returns (uint256) {
        vm.prank(who);
        return router.buy(address(token), imdIn, 0, block.timestamp);
    }

    function _sell(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return router.sell(address(token), amount, 0, block.timestamp);
    }

    function _stock(uint256 asset) internal view returns (MockStock) {
        return stocks[asset - 1];
    }

    // ------------------------------------------------------------ opening the pool

    function test_openPool_locksWholeSupplyInPool() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertApproxEqAbs(token.balanceOf(address(pm)), SUPPLY, 1.01e9); // the 1e9 buffer (plus rounding) is burned
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.eligibleSupply(), 0);
        assertEq(hook.token(), address(token));
        assertApproxEqRel(hook.marketCap(address(token)), START_MCAP, 0.03e18);
        assertEq(token.name(), "The Zero Person Billion Dollar Company");
        assertEq(token.symbol(), "COMPANY");
        assertEq(token.owner(), address(0));
        address[6] memory a = token.assetList();
        assertEq(a[0], address(imd));
        for (uint256 i; i < 5; i++) {
            assertEq(a[i + 1], address(stocks[i]));
        }
    }

    function test_openPool_onlyOnceAndOnlyOwner() public {
        vm.prank(owner);
        vm.expectRevert(CompanyHook.AlreadyLaunched.selector);
        hook.openPool(address(token));
        vm.prank(bob);
        vm.expectRevert(CompanyHook.NotOwner.selector);
        hook.openPool(address(token));
        vm.expectRevert(CompanyHook.NotSupported.selector);
        router.launch("x", "x", "", address(imd), 0, 0);
    }

    function test_constructor_rejectsMissingPoolsAndDuplicateStocks() public {
        address[5] memory s;
        CompanyToken.Pool[5] memory pools;
        for (uint256 i; i < 5; i++) {
            s[i] = address(stocks[i]);
            pools[i] = CompanyToken.Pool(3000, 60);
        }
        vm.expectRevert(CompanyToken.BadPool.selector);
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(3000, 60), s, pools, _oracles());
        pools[2] = CompanyToken.Pool(500, 10);
        vm.expectRevert(CompanyToken.BadPool.selector);
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools, _oracles());
        pools[2] = CompanyToken.Pool(3000, 60);
        s[4] = s[0];
        vm.expectRevert(CompanyToken.BadAsset.selector);
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools, _oracles());
    }

    function test_hook_blocksOutsidePoolsAndLiquidity() public {
        PoolKey memory k = hook.poolKey(address(token));
        vm.expectRevert();
        lp.modifyLiquidity(k, ModifyLiquidityParams(-887200, 887200, 1e18, 0), "");
        PoolKey memory other = PoolKey(k.currency0, k.currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        pm.initialize(other, TickMath.getSqrtPriceAtTick(0));
    }

    // ------------------------------------------------------------ fees and split

    function test_buy_feeSplit_1pctProtocol_3pctHolders() public {
        _buy(alice, 1_000e18);
        assertEq(hook.pendingProtocolFees(address(imd)), 10e18);
        // nobody held before, so the 30 IMD wait in the token
        assertEq(imd.balanceOf(address(token)), 30e18);
        assertEq(token.owed(0), 0);

        _buy(bob, 1_000e18);
        // alice held everything when 60 IMD were distributed: 30 IMD rewards, 6 IMD reserved per stock
        assertEq(token.owed(0), 30e18);
        for (uint256 a = 1; a <= 5; a++) {
            assertEq(token.pendingConvert(a), 6e18);
        }
        assertApproxEqAbs(token.withdrawableRewardOf(alice, 0), 30e18, 10);
        assertEq(token.withdrawableRewardOf(bob, 0), 0, "buyer earns nothing from its own trade");
    }

    function test_sell_paysFeeToo() public {
        uint256 got = _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        uint256 owedBefore = token.owed(0);
        uint256 out = _sell(alice, got);
        // 4% of the gross: out is 96%
        uint256 fee = (out * 400) / 9600;
        assertApproxEqAbs(token.owed(0) - owedBefore, (fee * 3 / 4) / 2, 1e6);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_buyWithEth_throughEthRouter() public {
        vm.prank(alice);
        uint256 got = ethRouter.buyWithEth{value: 5 ether}(address(token), 0, block.timestamp);
        assertGt(got, 0);
        assertEq(token.balanceOf(alice), got);
    }

    function test_thirdPartyRouter_paysFeeAndFlushesLater() public {
        _buy(alice, 1_000e18);
        PoolKey memory k = hook.poolKey(address(token));
        bool zeroForOne = Currency.unwrap(k.currency0) == address(imd);
        vm.prank(bob);
        extRouter.swap(
            k,
            SwapParams(zeroForOne, -100e18, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        assertEq(hook.pendingHolderFees(address(token)), 3e18);
        vm.prank(alice);
        token.claim();
        assertEq(hook.pendingHolderFees(address(token)), 0);
    }

    // ------------------------------------------------------------ claims

    function test_claim_paysImd() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertApproxEqAbs(paid[0], 30e18, 10);
        assertEq(imd.balanceOf(alice) - before, paid[0]);
        assertEq(token.withdrawableRewardOf(alice, 0), 0);
    }

    function test_minHolding_smallWalletsEarnNothing() public {
        uint256 got = _buy(alice, 1_000e18);
        // carol gets 99,999 $COMPANY: below the 100,000 minimum
        vm.prank(alice);
        token.transfer(carol, 99_999e18);
        assertEq(token.weightOf(carol), 0);
        assertEq(token.weightOf(alice), got - 99_999e18);
        _buy(bob, 1_000e18);
        assertEq(token.withdrawableRewardOf(carol, 0), 0, "below minimum earns nothing");
        assertApproxEqAbs(token.withdrawableRewardOf(alice, 0), 30e18, 10, "alice earned all of it");

        // one more token takes carol to 100,000: she earns from then on, never retroactively
        vm.prank(alice);
        token.transfer(carol, 1e18);
        assertEq(token.weightOf(carol), 100_000e18);
        assertEq(token.withdrawableRewardOf(carol, 0), 0);
        _buy(bob, 1_000e18);
        assertGt(token.withdrawableRewardOf(carol, 0), 0);

        // dropping below the minimum keeps what was earned but stops earning
        uint256 earned = token.withdrawableRewardOf(carol, 0);
        vm.prank(carol);
        token.transfer(alice, 2e18);
        assertEq(token.weightOf(carol), 0);
        _buy(bob, 1_000e18);
        assertEq(token.withdrawableRewardOf(carol, 0), earned);
    }

    function test_minHolding_eligibleSupplyIsSumOfWeights() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.prank(alice);
        token.transfer(carol, 50_000e18);
        assertEq(token.eligibleSupply(), token.weightOf(alice) + token.weightOf(bob) + token.weightOf(carol));
        assertEq(token.weightOf(carol), 0);
    }

    function test_transfer_keepsEarnedRewardsWithSender() public {
        uint256 got = _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        uint256 earned = token.withdrawableRewardOf(alice, 0);
        vm.prank(alice);
        token.transfer(carol, got);
        assertEq(token.withdrawableRewardOf(alice, 0), earned);
        assertEq(token.withdrawableRewardOf(carol, 0), 0);
    }

    // ------------------------------------------------------------ conversion

    function test_convert_buysStockAndCreditsHoldersProRata() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        uint256 cap = token.maxConvert() / 5; // 20 IMD per round (the fixed ceiling), shared by five stocks
        uint256[6] memory out = token.convert();
        // 4 IMD -> ~3.964 USDG (0.9%) -> ~3.95 NVDA (0.3%), small price impact
        assertApproxEqRel(out[1], 3.95e18, 0.01e18);
        assertEq(token.pendingConvert(1), 6e18 - cap);
        assertEq(token.owed(1), out[1]);
        uint256 a = token.withdrawableRewardOf(alice, 1);
        uint256 b = token.withdrawableRewardOf(bob, 1);
        assertApproxEqAbs(a + b, out[1], 10);
        assertApproxEqRel(a * 1e18 / b, token.balanceOf(alice) * 1e18 / token.balanceOf(bob), 1e9);
    }

    function test_claim_convertsFirst_andPaysAllSixAssets() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        // no separate convert call: claiming converts every stock's reserve, then pays it out
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        for (uint256 s = 0; s <= 5; s++) {
            assertGt(paid[s], 0);
            if (s > 0) assertLt(token.pendingConvert(s), 6e18, "reserve converted");
        }
        assertEq(_stock(1).balanceOf(alice), paid[1]);
        assertEq(token.withdrawableRewardOf(alice, 1), 0);
    }

    function test_convert_capSharedByStocks_onePerMinute() public {
        _buy(alice, 1_000e18);
        // ~1,000 IMD of holder fees reserved: ~100 IMD per stock, far above the 25 IMD round cap
        for (uint256 i; i < 10; i++) {
            _buy(bob, 3_333e18);
        }
        assertEq(token.maxConvert(), 20e18, "fixed ceiling below 0.25% of depth");

        vm.warp(block.timestamp + 1 minutes);
        uint256[6] memory pending;
        for (uint256 s = 1; s <= 5; s++) {
            pending[s] = token.pendingConvert(s);
        }
        uint256 cap = token.maxConvert() / 5;
        uint256 imdBefore = imd.balanceOf(address(token));
        token.convert();
        // the whole round sold at most 0.25% of the IMD/USDG depth
        assertEq(imdBefore - imd.balanceOf(address(token)), cap * 5);
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(token.pendingConvert(s), pending[s] - cap);
        }

        // claiming again in the same block (e.g. many claims in one transaction) converts nothing more
        vm.prank(alice);
        token.claim();
        vm.prank(bob);
        token.claim();
        uint256[6] memory again = token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(again[s], 0);
            assertEq(token.pendingConvert(s), pending[s] - cap);
        }

        vm.warp(block.timestamp + 1 minutes);
        again = token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertGt(again[s], 0);
        }
    }

    function test_convert_nothingPending_noRevert() public {
        vm.warp(block.timestamp + 1 minutes);
        uint256[6] memory out = token.convert();
        for (uint256 s; s <= 5; s++) {
            assertEq(out[s], 0);
        }
    }

    function test_convertStock_onlySelf() public {
        vm.expectRevert(CompanyToken.NotSelf.selector);
        token.convertStock(1, 1e18);
    }

    // ------------------------------------------------------------ blocked addresses

    function test_blockedHolder_stockStaysClaimable_othersPaid() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        token.convert();
        uint256 nvda = token.withdrawableRewardOf(alice, 1);

        _stock(1).setBlocked(alice, true);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[1], 0, "blocked stock skipped");
        assertGt(paid[0], 0, "IMD still paid");
        assertGt(paid[2], 0, "other stocks still paid");
        assertEq(token.withdrawableRewardOf(alice, 1), nvda, "still claimable");

        _stock(1).setBlocked(alice, false);
        vm.prank(alice);
        paid = token.claim();
        assertEq(paid[1], nvda);
    }

    function test_stockThatCantBeBought_isPaidAsImdInTheSameClaim() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        _stock(4).setBlocked(address(token), true); // GME refuses the token contract
        vm.warp(block.timestamp + 1 minutes);
        uint256 round = token.maxConvert() / 5;
        uint256 owedImd = token.owed(0);
        uint256 aliceImd = token.withdrawableRewardOf(alice, 0);

        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[4], 0, "no GME");
        assertGt(paid[1], 0, "other stocks bought and paid");
        // this round's GME money went to holders as IMD, at once
        assertEq(token.pendingConvert(4), 6e18 - round, "one round moved");
        assertEq(token.owed(0) + paid[0], owedImd + round, "credited as IMD");
        assertGt(paid[0], aliceImd, "alice got her share of it now");

        // while GME stays blocked, every round hands the next part over as IMD, until nothing waits
        for (uint256 i; i < 10 && token.pendingConvert(4) > 0; i++) {
            vm.warp(block.timestamp + 1 minutes);
            token.convert();
        }
        assertEq(token.pendingConvert(4), 0);
    }

    function test_lowGasClaim_succeeds_skipsStocks_neverTurnsThemIntoImd() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        uint256 pending = token.pendingConvert(1);
        uint256 aliceImd = token.withdrawableRewardOf(alice, 0);
        // a claim sent with an estimate made before the round was due (or by someone starving purchases of gas)
        vm.prank(alice);
        (bool ok,) = address(token).call{gas: 900_000}(abi.encodeCall(CompanyToken.claim, ()));
        assertTrue(ok, "the claim goes through");
        assertEq(token.pendingConvert(1), pending, "stocks skipped, not bought and not turned into IMD");
        assertEq(imd.balanceOf(alice) >= aliceImd, true);
        assertEq(token.withdrawableRewardOf(alice, 0), 0, "her IMD was paid");
        // the next claim with enough gas buys them as usual
        vm.prank(bob);
        uint256[6] memory paid = token.claim();
        assertGt(paid[1], 0);
    }

    // ------------------------------------------------------------ IMD Swarm re-check f1d5def3

    /// @dev Finding 1 (medium): the auditors' sequence on a thin NVDA pool. The Chainlink check makes the round skip
    ///      instead of buying at the attacker's price, and the attacker loses money.
    function test_recheck1_oracleStopsJitSandwichOfThinStockPool() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -999_990e18, 0), "");
        vm.warp(block.timestamp + 1 minutes);
        address attacker = makeAddr("attacker");
        usdg.mint(attacker, 100_000e18);
        stocks[0].mint(attacker, 100_000e18);
        bool usdIs0 = address(usdg) < address(stocks[0]);
        vm.startPrank(attacker);
        usdg.approve(address(extRouter), type(uint256).max);
        stocks[0].approve(address(extRouter), type(uint256).max);
        usdg.approve(address(lp), type(uint256).max);
        stocks[0].approve(address(lp), type(uint256).max);
        uint256 before = usdg.balanceOf(attacker) + stocks[0].balanceOf(attacker);
        // (1) push NVDA's price up (the direction the round's purchase moves it)
        extRouter.swap(
            nk,
            SwapParams(usdIs0, -30e18, usdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        // (2) mint a large narrow position around the pushed tick
        (, int24 tick,,) = pm.getSlot0(nk.toId());
        int24 lower = (tick / 60) * 60 - 60;
        if (tick < 0 && tick % 60 != 0) lower -= 60;
        lp.modifyLiquidity(nk, ModifyLiquidityParams(lower, lower + 180, 50_000e18, 0), "");
        vm.stopPrank();
        assertGt(token.stockRoundLimit(1), 4e18, "depth reading inflated, as in the report");
        // (3) the round
        uint256 pending = token.pendingConvert(1);
        uint256 nvdaHeld = stocks[0].balanceOf(address(token));
        token.convert();
        assertEq(token.pendingConvert(1), pending, "NVDA round skipped (price off Chainlink)");
        assertEq(stocks[0].balanceOf(address(token)), nvdaHeld, "nothing bought at the attacker's price");
        // (4) remove the position, (5) swap back
        vm.startPrank(attacker);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(lower, lower + 180, -50_000e18, 0), "");
        uint256 nvdaGot = stocks[0].balanceOf(attacker) > 100_000e18 ? stocks[0].balanceOf(attacker) - 100_000e18 : 0;
        if (nvdaGot > 0) {
            extRouter.swap(
                nk,
                SwapParams(
                    !usdIs0, -int256(nvdaGot), !usdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                settings,
                ""
            );
        }
        vm.stopPrank();
        assertLe(usdg.balanceOf(attacker) + stocks[0].balanceOf(attacker), before, "sandwich not profitable");
    }

    /// @dev Finding 1, other stocks: a price that drifts more than 3% from Chainlink also just skips that stock.
    function test_recheck1_priceAwayFromOracle_skipsOnlyThatStock() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        feeds[1].set(0.95e8, block.timestamp); // Chainlink says GOOGL is 5% cheaper than its pool
        uint256[6] memory out = token.convert();
        assertEq(out[2], 0, "GOOGL skipped");
        assertEq(token.pendingConvert(2), 6e18, "GOOGL reserve untouched, not turned into IMD");
        assertGt(out[1], 0, "NVDA bought");
    }

    function test_recheck1_staleFeed_holdsThatStock() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 5 days);
        feeds[0].set(1e8, block.timestamp - 4 days - 1); // NVDA feed older than MAX_ORACLE_AGE
        for (uint256 i = 1; i < 5; i++) {
            feeds[i].set(1e8, block.timestamp);
        }
        usdFeed.set(1e8, block.timestamp);
        ethFeed.set(1e8, block.timestamp);
        uint256[6] memory out = token.convert();
        assertEq(out[1], 0);
        assertEq(token.pendingConvert(1), 6e18, "waits for a fresh price");
        assertGt(out[2], 0);
        vm.expectRevert(CompanyToken.PriceOff.selector);
        token.minStockOut(1, 1e18);
    }

    /// @dev f1d5def3 finding 2 / 4d037a63 finding 3: no liquidity at the stock pool's price. Nothing is swapped, so a
    ///      far resting position can't sell into the round; the stock waits (nothing paid as IMD at once).
    function test_recheck2_zeroLiquidityRoundPaidAsImd_noSwap() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -1_000_000e18, 0), "");
        address attacker = makeAddr("attacker");
        usdg.mint(attacker, 10_000e18);
        stocks[0].mint(attacker, 10_000e18);
        vm.startPrank(attacker);
        usdg.approve(address(lp), type(uint256).max);
        stocks[0].approve(address(lp), type(uint256).max);
        bool usdIs0 = address(usdg) < address(stocks[0]);
        int24 lo = usdIs0 ? int24(46020) : int24(-46080);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(lo, lo + 60, 2_000e18, 0), "");
        vm.stopPrank();
        assertEq(token.stockRoundLimit(1), 0);
        vm.warp(block.timestamp + 1 minutes);
        uint256 owedImd = token.owed(0);
        uint256 nvdaHeld = stocks[0].balanceOf(address(token));
        token.convert();
        assertEq(stocks[0].balanceOf(address(token)), nvdaHeld, "no NVDA bought from the resting position");
        assertEq(token.owed(0), owedImd, "not paid as IMD at once: the stock waits");
        assertEq(token.pendingConvert(1), 6e18);
    }

    // ------------------------------------------------------------ expiry

    function test_expiry_inactiveWalletLosesOldRewards_allAssets() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        token.convert();
        uint256 oldImd = token.withdrawableRewardOf(alice, 0);
        uint256 oldNvda = token.withdrawableRewardOf(alice, 1);

        vm.warp(block.timestamp + 8 days);
        assertEq(token.expiredRewardsOf(alice, 0), oldImd);
        assertEq(token.expiredRewardsOf(alice, 1), oldNvda);

        // new rewards, earned in the last 7 days, never expire
        _buy(carol, 1_000e18);
        uint256 recentImd = token.withdrawableRewardOf(alice, 0) - oldImd;
        assertGt(recentImd, 0);

        uint256 feeImd = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(carol);
        uint256[6] memory expired = token.recycle(alice);
        assertEq(expired[0], oldImd);
        assertEq(expired[1], oldNvda);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeImd, oldImd);
        assertEq(_stock(1).balanceOf(FEE_RECIPIENT), oldNvda);
        assertApproxEqAbs(token.withdrawableRewardOf(alice, 0), recentImd, 2);
        assertEq(token.withdrawableRewardOf(alice, 1), 0);
    }

    function test_expiry_activeWalletKeepsEverything() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        uint256 w = token.withdrawableRewardOf(alice, 0);
        vm.warp(block.timestamp + 6 days);
        vm.prank(alice);
        token.transfer(carol, 1e18); // sending is activity
        vm.warp(block.timestamp + 6 days);
        assertEq(token.expiredRewardsOf(alice, 0), 0);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[0], w);
    }

    function test_expiry_claimIsStrict() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        uint256 w = token.withdrawableRewardOf(alice, 0);
        vm.warp(block.timestamp + 8 days);
        uint256 feeImd = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[0], 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeImd, w);
    }

    function test_expiry_giftDoesNotResetTimer_buyDoes_afterForfeiting() public {
        _buy(alice, 1_000e18);
        uint256 got = _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        token.transfer(alice, got / 2);
        uint256 expired = token.expiredRewardsOf(alice, 0);
        assertGt(expired, 0, "gift is not activity");
        uint256 withdrawable = token.withdrawableRewardOf(alice, 0);
        _buy(alice, 1e18);
        assertEq(token.lastActive(alice), block.timestamp, "a buy is activity");
        assertEq(token.expiredRewardsOf(alice, 0), 0);
        assertEq(token.recycledHeld(0), expired, "but what had expired went to the protocol first");
        assertGe(token.withdrawableRewardOf(alice, 0), withdrawable - expired);
    }

    function test_markActive_onlyHook() public {
        vm.expectRevert(CompanyToken.NotHook.selector);
        token.markActive(alice);
    }

    function test_expiry_sellIsActivity() public {
        uint256 got = _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 6 days);
        _sell(alice, got / 10);
        assertEq(token.lastActive(alice), block.timestamp);
    }

    // ------------------------------------------------------------ flash-borrow guard

    function test_flashBorrowedTokens_cannotCaptureRewards() public {
        _buy(alice, 1_000e18);
        PoolKey memory k = hook.poolKey(address(token));
        bool zeroForOne = Currency.unwrap(k.currency0) == address(imd);
        vm.prank(bob);
        extRouter.swap(
            k,
            SwapParams(zeroForOne, -1_000e18, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        // holder fees wait in the hook; a flash holder tries to have them distributed while holding the pool
        FlashHolder f = new FlashHolder(IPoolManager(address(pm)), token);
        f.run(1);
        vm.expectRevert(); // claim refuses to run inside someone else's unlock (audit 363ab052, finding 2)
        f.run(4);
        assertEq(token.withdrawableRewardOf(address(f), 0), 0);
        assertEq(hook.pendingHolderFees(address(token)), 30e18, "nothing distributed mid-unlock");

        // stock donations can't be captured mid-unlock either
        _stock(1).mint(address(token), 100e18);
        f.run(2);
        assertEq(token.owed(1), 0);

        // and nothing converts inside someone else's unlock (neither directly nor through claim)
        vm.warp(block.timestamp + 1 minutes);
        vm.prank(alice);
        token.claim(); // outside an unlock: distributes and converts the first round
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        uint256 pending = token.pendingConvert(1);
        f.run(3);
        vm.expectRevert();
        f.run(4);
        assertEq(token.pendingConvert(1), pending, "no conversion mid-unlock");
    }

    function test_distributeStock_creditsDonationsAndRebases() public {
        _buy(alice, 1_000e18);
        _stock(3).mint(address(token), 50e18);
        assertEq(token.distributeStock(3), 50e18);
        assertApproxEqAbs(token.withdrawableRewardOf(alice, 3), 50e18, 10);
        assertEq(token.distributeStock(3), 0);
    }

    // ------------------------------------------------------------ IMD Swarm audit 78c00339

    /// @dev Finding 1 (high): just-in-time liquidity inflates the depth-based cap. The fixed ceiling holds the round
    ///      to 20 IMD and the sandwich loses money (the audit's exact sequence).
    function test_audit1_jitLiquidityCannotInflateRound() public {
        _buy(alice, 1_000e18);
        for (uint256 i; i < 10; i++) {
            _buy(bob, 3_333e18);
        }
        vm.warp(block.timestamp + 1 minutes);
        PoolKey memory k = _key(address(imd), address(usdg), 9000, 90);
        bool imdIs0 = address(imd) < address(usdg);
        address attacker = makeAddr("attacker");
        imd.mint(attacker, 1_000_000e18);
        usdg.mint(attacker, 1_000_000e18);
        vm.startPrank(attacker);
        imd.approve(address(extRouter), type(uint256).max);
        usdg.approve(address(extRouter), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        usdg.approve(address(lp), type(uint256).max);
        uint256 before = imd.balanceOf(attacker) + usdg.balanceOf(attacker);
        // (1) push the price
        extRouter.swap(
            k,
            SwapParams(imdIs0, -10_000e18, imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        // (2) add a narrow position around the new tick
        (, int24 tick,,) = pm.getSlot0(k.toId());
        int24 lower = (tick / 90) * 90 - 90;
        if (tick < 0 && tick % 90 != 0) lower -= 90;
        lp.modifyLiquidity(k, ModifyLiquidityParams(lower, lower + 270, 2_000_000e18, 0), "");
        vm.stopPrank();
        assertEq(token.maxConvert(), 20e18, "cap can't be inflated");
        // (3) the round
        uint256 tokenImd = imd.balanceOf(address(token));
        token.convert();
        assertLe(tokenImd - imd.balanceOf(address(token)), 20e18, "round sells at most 20 IMD");
        // (4) remove the position, (5) swap back
        vm.startPrank(attacker);
        lp.modifyLiquidity(k, ModifyLiquidityParams(lower, lower + 270, -2_000_000e18, 0), "");
        uint256 usdGained =
            usdg.balanceOf(attacker) + 10_000e18 > 1_000_000e18 ? usdg.balanceOf(attacker) - 1_000_000e18 : 0;
        extRouter.swap(
            k,
            SwapParams(
                !imdIs0, -int256(usdGained), !imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
        assertLe(imd.balanceOf(attacker) + usdg.balanceOf(attacker), before, "sandwich not profitable");
    }

    /// @dev Finding 2 (78c00339): each stock's round is also limited by its own pool.
    function test_audit2_thinStockPoolLimitsItsRound() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        assertApproxEqRel(token.stockRoundLimit(1), 1_500e18, 0.01e18);
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -999_000e18, 0), "");
        uint256 limit = token.stockRoundLimit(1);
        assertApproxEqRel(limit, 1.5e18, 0.01e18);
        vm.warp(block.timestamp + 1 minutes);
        uint256 pending = token.pendingConvert(1);
        token.convert();
        assertEq(pending - token.pendingConvert(1), limit, "NVDA round held to its pool's limit");
    }

    /// @dev Finding 3: a swap that fills only part of an IMD-specified request is rejected instead of overpaying.
    function test_audit3_partialFillIsRejected_fullFillWorks() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory k = hook.poolKey(address(token));
        bool imdIs0 = Currency.unwrap(k.currency0) == address(imd);
        (, int24 tick,,) = pm.getSlot0(k.toId());
        // selling $COMPANY for an exact 3,000 IMD, with a price limit it hits first
        uint160 limit = TickMath.getSqrtPriceAtTick(imdIs0 ? tick + 2000 : tick - 2000);
        vm.prank(alice);
        token.approve(address(extRouter), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        extRouter.swap(k, SwapParams(!imdIs0, 3_000e18, limit), settings, "");
        // the same exact-out sell for a small amount fills fully and pays exactly 4%
        uint256 fees = hook.pendingHolderFees(address(token)) + hook.pendingProtocolFees(address(imd));
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        extRouter.swap(
            k,
            SwapParams(!imdIs0, 10e18, !imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        assertEq(imd.balanceOf(alice) - imdBefore, 10e18);
        assertEq(
            hook.pendingHolderFees(address(token)) + hook.pendingProtocolFees(address(imd)) - fees,
            (uint256(10e18) * 400) / 9600
        );
    }

    /// @dev Finding 4: moving 1 wei out of the PoolManager no longer resets anyone's expiry timer.
    function test_audit4_poolManagerPingDoesNotResetTimer() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        TimerPinger pinger = new TimerPinger(IPoolManager(address(pm)), token);
        vm.prank(bob);
        token.transfer(address(pinger), 1);
        vm.warp(block.timestamp + 8 days);
        uint256 expired = token.expiredRewardsOf(alice, 0);
        assertGt(expired, 0);
        uint256 last = token.lastActive(alice);
        pinger.ping(alice);
        assertEq(token.lastActive(alice), last, "timer not reset");
        assertEq(token.expiredRewardsOf(alice, 0), expired);
    }

    /// @dev Finding 8: expired stock the fee recipient can't receive is held for it, not paid to the claimer.
    function test_audit8_expiredStockHeldWhenFeeRecipientBlocked() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        token.convert();
        vm.warp(block.timestamp + 8 days);
        token.convert(); // this minute's round, so the claim below buys nothing new
        uint256 nvda = token.expiredRewardsOf(alice, 1);
        uint256 withdrawable = token.withdrawableRewardOf(alice, 1);
        assertGt(nvda, 0);
        _stock(1).setBlocked(FEE_RECIPIENT, true);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[1], withdrawable - nvda, "only the recent NVDA is paid; the expired part isn't");
        assertEq(token.recycledHeld(1), nvda, "held for the fee recipient");
        assertEq(token.sendRecycled(1), 0, "still refused");
        _stock(1).setBlocked(FEE_RECIPIENT, false);
        assertEq(token.sendRecycled(1), nvda);
        assertEq(_stock(1).balanceOf(FEE_RECIPIENT), nvda);
        assertEq(token.recycledHeld(1), 0);
    }

    /// @dev Finding 9: trades through the ETH router are logged with the real buyer, not tx.origin.
    function test_audit9_ethRouterTradeLogsRealBuyer() public {
        _buy(alice, 1_000e18);
        address wallet = makeAddr("contractWallet");
        vm.deal(wallet, 10 ether);
        vm.expectEmit(true, true, false, false, address(hook));
        emit CompanyHook.Trade(address(token), wallet, true, 0, 0, 0, 0);
        vm.prank(wallet, alice); // msg.sender = wallet, tx.origin = alice
        ethRouter.buyWithEth{value: 1 ether}(address(token), 0, block.timestamp);
    }

    // ------------------------------------------------------------ IMD Swarm final check 363ab052

    /// @dev Finding 1 (high): an inactive wallet sending itself 1 wei no longer revives its expired rewards.
    function test_final1_selfTransferForfeitsExpiredFirst() public {
        _buy(alice, 20e18);
        _buy(bob, 20e18);
        vm.warp(block.timestamp + 8 days);
        _buy(bob, 10e18); // one distribution inside alice's last 7 days
        uint256 expired = token.expiredRewardsOf(alice, 0);
        uint256 withdrawable = token.withdrawableRewardOf(alice, 0);
        assertGt(expired, 0);
        vm.prank(alice);
        token.transfer(alice, 1);
        assertEq(token.recycledHeld(0), expired, "expired part moved to the protocol before the timer reset");
        assertEq(token.withdrawableRewardOf(alice, 0), withdrawable - expired);
        uint256 fee = imd.balanceOf(FEE_RECIPIENT);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[0], withdrawable - expired, "only the last 7 days are paid");
        assertEq(token.sendRecycled(0), expired);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - fee, expired);
    }

    /// @dev Finding 2 (high): a wallet can't claim inside a PoolManager unlock with borrowed pool tokens.
    function test_final2_claimWithBorrowedPoolTokensIsRefused() public {
        _buy(alice, 1_000e18);
        FlashHolder f = new FlashHolder(IPoolManager(address(pm)), token);
        uint256 half = token.balanceOf(alice) / 2;
        vm.prank(alice);
        token.transfer(address(f), half); // f's first receipt: it is active and earns
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 8 days);
        _buy(bob, 10e18);
        uint256 expired = token.expiredRewardsOf(address(f), 0);
        assertGt(expired, 0);
        vm.expectRevert();
        f.run(4); // borrow the pool's tokens, then claim
        assertEq(token.expiredRewardsOf(address(f), 0), expired, "nothing dodged");
        token.recycle(address(f));
        assertEq(token.expiredRewardsOf(address(f), 0), 0);
    }

    /// @dev 363ab052 finding 3: a stale feed waits; after 30 days of failed attempts the stock is paid as IMD.
    function test_final3_deadFeedFallsBackToImdAfter30Days() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        _attemptEvery6Days(6, 1);
        assertEq(token.pendingConvert(1), 6e18, "stale: waits");
        assertGt(token.pendingConvert(2), 6e18 - 4e18 - 1, "other stocks convert normally");
        _attemptEvery6Days(30, 1);
        assertEq(token.pendingConvert(1), 2e18, "dead: one full round paid as IMD");
    }

    /// @dev 363ab052 finding 3 / 986abba2 finding 4: an IMD/USDG pool with no liquidity. Rounds wait, then after
    ///      30 days of failed attempts (weekly claims are enough) they are paid as IMD.
    function test_final3_emptyImdPoolFallsBackToImdAfter30Days() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -10_000e18, 0), "");
        assertEq(token.maxConvert(), 0);
        _attemptEvery6Days(24, 0);
        assertEq(token.pendingConvert(1), 6e18, "waits");
        uint256 owedImd = token.owed(0);
        _attemptEvery6Days(12, 0);
        assertEq(token.owed(0), owedImd + 5 * 4e18, "every stock's round paid as IMD");
    }

    /// @dev 363ab052 finding 4: a dust position in an emptied stock pool neither buys dust nor blocks the fallback.
    function test_final4_dustPositionCountsAsEmpty() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -1_000_000e18, 0), "");
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, 2e9, 0), "");
        assertGt(token.stockRoundLimit(1), 0);
        _attemptEvery6Days(36, 0);
        assertEq(token.pendingConvert(1), 2e18, "paid as IMD after 30 days of failing");
    }

    /// @dev Finding 6 (info): the pool's own fee is excluded before the 3% tolerance, so a 2.5% gap still converts
    ///      in a 0.3% pool (it would have been skipped before).
    function test_final6_poolFeeExcludedFromTolerance() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        feeds[0].set(0.975e8, block.timestamp); // Chainlink 2.5% below the pool
        uint256[6] memory out = token.convert();
        assertGt(out[1], 0, "within 3% after the 0.3% fee: bought");
    }

    /// @dev Calls convert() every 6 days for `daysTotal` days (fresh feeds; `mode` 1 keeps NVDA's feed stale, 2 makes
    ///      it answer 0), as weekly claims would.
    function _attemptEvery6Days(uint256 daysTotal, uint256 mode) internal {
        for (uint256 t; t < daysTotal; t += 6) {
            vm.warp(block.timestamp + 6 days);
            _refreshFeedsExcept(mode == 0 ? 99 : 0);
            if (mode == 1) feeds[0].set(1e8, block.timestamp - 5 days);
            if (mode == 2) feeds[0].set(0, block.timestamp);
            token.convert();
        }
    }

    function _refreshFeedsExcept(uint256 skip) internal {
        usdFeed.set(1e8, block.timestamp);
        ethFeed.set(1e8, block.timestamp);
        for (uint256 i; i < 5; i++) {
            if (i != skip) feeds[i].set(1e8, block.timestamp);
        }
    }

    // ------------------------------------------------------------ IMD Swarm final check 2 882666b4

    function _expiredSetup() internal returns (uint256 expired) {
        _buy(alice, 20e18);
        _buy(bob, 20e18);
        vm.warp(block.timestamp + 8 days);
        _buy(bob, 10e18);
        expired = token.expiredRewardsOf(alice, 0);
        assertGt(expired, 0);
    }

    /// @dev Finding 1 (high): a send while holding flash-borrowed pool tokens still forfeits what expired.
    function test_final2_1_flashBorrowThenSend_stillForfeits() public {
        uint256 expired = _expiredSetup();
        FlashReviver f = new FlashReviver(IPoolManager(address(pm)), token, hook, address(imd));
        vm.prank(alice);
        token.approve(address(f), type(uint256).max); // approving is not activity
        f.run(alice, 1);
        assertEq(token.recycledHeld(0), expired, "expired rewards forfeited despite the borrowed balance");
    }

    /// @dev Finding 2 (high): a dust buy while holding flash-borrowed pool tokens still forfeits what expired.
    function test_final2_2_flashBorrowThenDustBuy_stillForfeits() public {
        uint256 expired = _expiredSetup();
        FlashReviver f = new FlashReviver(IPoolManager(address(pm)), token, hook, address(imd));
        imd.mint(address(f), 1e18);
        vm.prank(alice);
        token.approve(address(f), type(uint256).max);
        vm.prank(alice, alice); // tx.origin = alice: the hook records her as the buyer
        f.run(alice, 2);
        assertEq(token.lastActive(alice), block.timestamp, "the buy made her active");
        assertEq(token.recycledHeld(0), expired, "but only after forfeiting what had expired");
    }

    /// @dev 882666b4 finding 3: a dust IMD/USDG position can't buy a real round: skipped, then after 30 days of
    ///      failed attempts paid as IMD in full rounds.
    function test_final2_3_dustImdPoolStillCountsAsEmpty() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -10_000e18, 0), "");
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, 10_000, 0), "");
        assertGt(token.maxConvert(), 0);
        _attemptEvery6Days(24, 0);
        assertEq(token.pendingConvert(1), 6e18, "still waiting after 24 days");
        _attemptEvery6Days(12, 0);
        assertEq(token.pendingConvert(1), 2e18, "paid as IMD (full round) after 30 days of failing");
    }

    /// @dev 882666b4 finding 4: a feed that answers 0 holds the stock; it is paid as IMD only after 30 days of
    ///      failed attempts.
    function test_final2_4_unusableFeedHoldsUntilDeadAfter() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        feeds[0].set(0, block.timestamp);
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.pendingConvert(1), 6e18, "held, not paid as IMD");
        assertEq(token.owed(0), owedImd);
        _attemptEvery6Days(36, 2);
        assertLt(token.pendingConvert(1), 6e18, "paid as IMD after 30 days without a usable answer");
    }

    /// @dev The 30-day clock only counts waiting without a successful purchase: a stock bought at least once a
    ///      month never falls back, while one whose price stays off Chainlink falls back after 30 days.
    function test_stuckClock_onlyCountsWaitingWithoutAPurchase() public {
        // a deeper IMD/USDG pool, so a month of rounds doesn't move its price off the IMD/ETH reference
        lp.modifyLiquidity(
            _key(address(imd), address(usdg), 9000, 90), ModifyLiquidityParams(-FULL_90, FULL_90, 200_000e18, 0), ""
        );
        _buy(alice, 1_000e18);
        for (uint256 i; i < 10; i++) {
            _buy(bob, 3_333e18); // large reserves: many rounds
        }
        feeds[1].set(0.9e8, block.timestamp); // GOOGL 10% off: every GOOGL round is skipped
        for (uint256 d; d < 29; d++) {
            vm.warp(block.timestamp + 1 days);
            _refreshFeedsExcept(1);
            feeds[1].set(0.9e8, block.timestamp);
            token.convert();
        }
        assertEq(token.failingSince(1), 0, "NVDA kept converting: never failing");
        uint256 googlPending = token.pendingConvert(2);
        uint256 owedImd = token.owed(0);
        vm.warp(block.timestamp + 2 days);
        _refreshFeedsExcept(1);
        feeds[1].set(0.9e8, block.timestamp);
        token.convert();
        assertEq(token.pendingConvert(2), googlPending - 4e18, "GOOGL, stuck 30 days, paid one round as IMD");
        assertGe(token.owed(0), owedImd + 4e18);
    }

    // ------------------------------------------------------------ IMD Swarm final check 3 986abba2

    /// @dev Finding 1 (medium): an empty IMD/USDG pool, a position at a made-up price. The first-hop check skips the
    ///      round instead of selling the reserves into it for dust.
    function test_final3_1_madeUpPricePositionGetsNothing() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -10_000e18, 0), "");
        bool imdIs0 = address(imd) < address(usdg);
        address attacker = makeAddr("attacker");
        imd.mint(attacker, 1_000e18);
        usdg.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        imd.approve(address(extRouter), type(uint256).max);
        usdg.approve(address(extRouter), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        usdg.approve(address(lp), type(uint256).max);
        // move the empty pool's price for free to "IMD worth ~1e-9 USDG", then post a position there
        int24 target = imdIs0 ? int24(-207_000) : int24(207_000);
        extRouter.swap(ik, SwapParams(imdIs0, -1, TickMath.getSqrtPriceAtTick(target)), settings, "");
        lp.modifyLiquidity(ik, ModifyLiquidityParams(target - 900, target + 900, 3e16, 0), "");
        vm.stopPrank();
        assertGt(token.maxConvert(), 0.2e18, "the position makes the pool look non-empty");
        vm.warp(block.timestamp + 1 minutes);
        uint256 imdHeld = imd.balanceOf(address(token));
        token.convert();
        assertEq(imd.balanceOf(address(token)), imdHeld, "no IMD sold at the made-up price");
        assertEq(token.pendingConvert(1), 6e18);
    }

    /// @dev Finding 2 (low): a contract wallet that buys through a plain router and claims in the same transaction
    ///      keeps its share of what that claim distributes; only what expired before is recycled.
    function test_final3_2_buyAndClaimSameTxKeepsFreshRewards() public {
        BatchWallet w = new BatchWallet();
        imd.mint(address(w), 10_000e18);
        w.approve(address(imd), address(extRouter));
        PoolKey memory k = hook.poolKey(address(token));
        bool imdIs0 = Currency.unwrap(k.currency0) == address(imd);
        address signer = makeAddr("signer");
        vm.prank(signer, signer);
        w.buyAndClaim(extRouter, k, imdIs0, -20e18, CompanyToken(address(0))); // first buy: W active, earns
        _buy(bob, 20e18);
        vm.warp(block.timestamp + 8 days);
        _buy(bob, 10e18);
        uint256 expired = token.expiredRewardsOf(address(w), 0);
        assertGt(expired, 0);
        uint256 recycledBefore = token.totalRecycled(0);
        vm.prank(signer, signer);
        w.buyAndClaim(extRouter, k, imdIs0, -1_000e18, token);
        assertApproxEqAbs(token.totalRecycled(0) - recycledBefore, expired, 1e12, "only what had expired before");
    }

    /// @dev Findings 3 and 4 (low): after a long quiet period, one unusable feed read holds the stock (it is not
    ///      dead at once), and an abandoned pool needs no daily keeper (see test_final3_emptyImdPool...).
    function test_final3_3_unusableReadAfterQuietMonthHolds() public {
        vm.warp(block.timestamp + 31 days); // nobody trades
        _refreshFeedsExcept(99);
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        _refreshFeedsExcept(0);
        feeds[0].set(0, block.timestamp); // one unusable NVDA read
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.pendingConvert(1), 6e18, "held, not paid as IMD");
        assertEq(token.owed(0), owedImd);
    }

    // ------------------------------------------------------------ IMD Swarm final check 4 dddb75ec

    function _imdEthKey() internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 100, IHooks(address(0)));
    }

    /// @dev Pushes IMD's price in the IMD/ETH pool up by buying IMD with ETH (moves the reference ~12%).
    function _pushImdEth() internal {
        extRouter.swap{value: 600 ether}(
            _imdEthKey(), SwapParams(true, -600e18, TickMath.MIN_SQRT_PRICE + 1), settings, ""
        );
    }

    /// @dev dddb75ec finding 1, IMD/USDG side: a dust position at a made-up price doesn't throttle the fallback; once
    ///      it applies, it pays full 4 IMD rounds.
    function test_final4_1a_dustImdPositionDoesNotThrottleFallback() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -10_000e18, 0), "");
        bool imdIs0 = address(imd) < address(usdg);
        int24 target = imdIs0 ? int24(-207_000) : int24(207_000);
        extRouter.swap(ik, SwapParams(imdIs0, -1, TickMath.getSqrtPriceAtTick(target)), settings, "");
        lp.modifyLiquidity(ik, ModifyLiquidityParams(target - 90, target + 90, 2.6e15, 0), "");
        _attemptEvery6Days(36, 0);
        assertEq(token.pendingConvert(1), 2e18, "full 4 IMD round paid as IMD, not 0.04");
    }

    /// @dev dddb75ec finding 1 / 4d037a63 finding 1, stock side: a stock pool that can only take dust is never
    ///      bought as dust; it is skipped, and after 30 days of failing it pays full 4 IMD rounds.
    function test_final4_1b_dustStockPoolDoesNotThrottleFallback() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -1_000_000e18, 0), "");
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, 70e18, 0), "");
        assertGt(token.stockRoundLimit(1), 0.04e18);
        assertLt(token.stockRoundLimit(1), 0.4e18);
        uint256 nvdaHeld = stocks[0].balanceOf(address(token));
        _attemptEvery6Days(24, 0);
        assertEq(stocks[0].balanceOf(address(token)), nvdaHeld, "no dust purchases");
        assertEq(token.pendingConvert(1), 6e18);
        _attemptEvery6Days(12, 0);
        assertEq(token.pendingConvert(1), 2e18, "full 4 IMD round paid as IMD after 30 days");
    }

    /// @dev Finding 2 (low): after a quiet month, a weekend-stale feed only arms the clock; nothing is paid as IMD.
    function test_final4_2a_quietMonthThenStaleFeedDoesNotPay() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 31 days); // nobody claims or converts
        _refreshFeedsExcept(0);
        feeds[0].set(1e8, block.timestamp - 4 days - 1);
        uint256 owedImd = token.owed(0);
        token.convert();
        vm.warp(block.timestamp + 1 minutes);
        token.convert();
        assertEq(token.pendingConvert(1), 6e18, "healthy NVDA waits for its feed");
        assertEq(token.owed(0) - owedImd, 0, "nothing paid as IMD for NVDA");
        // the feed updates on Monday: NVDA is bought as usual
        vm.warp(block.timestamp + 1 hours);
        _refreshFeedsExcept(99);
        uint256[6] memory out = token.convert();
        assertGt(out[1], 0);
    }

    /// @dev Finding 2: after a quiet month, pushing IMD/ETH far from IMD/USDG only skips; nothing is paid as IMD.
    function test_final4_2b_quietMonthThenImdEthPushDoesNotPay() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 31 days);
        _refreshFeedsExcept(99);
        _pushImdEth();
        uint256 owedImd = token.owed(0);
        token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(token.pendingConvert(s), 6e18);
        }
        assertEq(token.owed(0), owedImd);
    }

    /// @dev Finding 3 (low): in an exhausted IMD/USDG pool, a single-sided IMD position (made-up high price, or the
    ///      true price) makes nothing fall back at once.
    function test_final4_3_singleSidedImdPositionDoesNotForceFallback() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -10_000e18, 0), "");
        bool imdIs0 = address(imd) < address(usdg);
        // (1) made-up high IMD price, IMD-only position
        int24 high = imdIs0 ? int24(108_000) : int24(-108_000);
        extRouter.swap(ik, SwapParams(!imdIs0, -1, TickMath.getSqrtPriceAtTick(high)), settings, "");
        int24 lo = imdIs0 ? high : high - 90;
        lp.modifyLiquidity(ik, ModifyLiquidityParams(lo, lo + 90, 2e24, 0), "");
        vm.warp(block.timestamp + 1 minutes);
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.owed(0), owedImd, "no immediate fallback at a made-up price");
        lp.modifyLiquidity(ik, ModifyLiquidityParams(lo, lo + 90, -2e24, 0), "");
        // (2) the true price, IMD-only position: the IMD/USDG side can't fill, which is a skip, not a stock failure
        extRouter.swap(ik, SwapParams(imdIs0, -1, TickMath.getSqrtPriceAtTick(0)), settings, "");
        lo = imdIs0 ? int24(0) : int24(-90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(lo, lo + 90, 8_000e18, 0), "");
        vm.warp(block.timestamp + 1 minutes);
        token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(token.pendingConvert(s), 6e18, "reserves unchanged");
        }
        assertEq(token.owed(0), owedImd);
    }

    /// @dev Finding 4 (info): the price checks subtract Uniswap's protocol fee as well as the LP fee.
    function test_final4_4_protocolFeeCountsInPriceChecks() public {
        uint256 before = token.minStockOut(1, 1_000e18);
        pm.setProtocolFeeController(address(this));
        PoolKey memory nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        pm.setProtocolFee(nk, uint24((1000 << 12) | 1000)); // 0.1% each way, as on Robinhood Chain
        uint256 afterFee = token.minStockOut(1, 1_000e18);
        // swap fee 0.3% -> 0.3997%
        assertApproxEqRel(afterFee * 1e18 / before, uint256(1_000_000 - 3997) * 1e18 / (1_000_000 - 3000), 1e12);
    }

    /// @dev Finding 6 (info): IMD/ETH drifting more than 10% from IMD/USDG skips every stock (nothing is paid as IMD
    ///      before 30 days), and a stale ETH/USD or USDG/USD feed holds all five stocks.
    function test_final4_6a_imdEthDriftSkipsEverything() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        _pushImdEth();
        uint256 owedImd = token.owed(0);
        uint256[6] memory out = token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(out[s], 0);
            assertEq(token.pendingConvert(s), 6e18);
        }
        assertEq(token.owed(0), owedImd);
    }

    function test_final4_6b_staleEthOrUsdgFeedHoldsEverything() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        ethFeed.set(1e8, block.timestamp - 4 days - 1);
        uint256[6] memory out = token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(out[s], 0);
            assertEq(token.pendingConvert(s), 6e18);
        }
        ethFeed.set(1e8, block.timestamp);
        usdFeed.set(1e8, block.timestamp - 4 days - 1);
        vm.warp(block.timestamp + 1 minutes);
        out = token.convert();
        for (uint256 s = 1; s <= 5; s++) {
            assertEq(out[s], 0);
            assertEq(token.pendingConvert(s), 6e18);
        }
    }

    // ------------------------------------------------------------ IMD Swarm final check 5 4d037a63

    /// @dev Replaces the NVDA pool's full-range liquidity with one position [-600, 600] of `liquidity`.
    function _concentrateNvda(uint128 liquidity) internal returns (PoolKey memory nk, bool usdIs0) {
        nk = _key(address(usdg), address(stocks[0]), 3000, 60);
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-FULL_60, FULL_60, -1_000_000e18, 0), "");
        lp.modifyLiquidity(nk, ModifyLiquidityParams(-600, 600, int256(uint256(liquidity)), 0), "");
        usdIs0 = address(usdg) < address(stocks[0]);
        usdg.approve(address(extRouter), type(uint256).max);
        stocks[0].approve(address(extRouter), type(uint256).max);
    }

    /// @dev Finding 2 (low): one skip, then a quiet month, then a weekend-stale feed: the gap restarts the clock, so
    ///      nothing is paid as IMD.
    function test_final5_2_isolatedSkipThenQuietMonthDoesNotPay() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        feeds[0].set(0.95e8, block.timestamp); // NVDA 5% off its pool: skipped once
        token.convert();
        assertGt(token.failingSince(1), 0);
        vm.warp(block.timestamp + 31 days); // nobody claims
        _refreshFeedsExcept(0);
        feeds[0].set(1e8, block.timestamp - 4 days - 1); // a long weekend
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.pendingConvert(1), 6e18, "healthy NVDA waits");
        assertEq(token.owed(0), owedImd, "nothing paid as IMD");
        assertEq(token.failingSince(1), block.timestamp, "the clock restarted");
    }

    /// @dev Finding 3 (low): the price sits in a gap just outside the only position (zero liquidity at the tick) but
    ///      a purchase would fill. It is not paid as IMD at once.
    function test_final5_3_priceInGapIsNotPaidAsImdAtOnce() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        (PoolKey memory nk, bool usdIs0) = _concentrateNvda(1e24);
        // sell NVDA past the position's edge
        int24 edge = usdIs0 ? int24(660) : int24(-660);
        extRouter.swap(nk, SwapParams(!usdIs0, -200_000e18, TickMath.getSqrtPriceAtTick(edge)), settings, "");
        assertEq(pm.getLiquidity(nk.toId()), 0);
        vm.warp(block.timestamp + 1 minutes);
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.owed(0), owedImd, "not paid as IMD at once");
    }

    /// @dev Finding 4 (low): near the edge of a thin position the round can't fully fill. That's a skip, not an
    ///      immediate IMD payout.
    function test_final5_4_partialFillNearEdgeIsASkip() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        (PoolKey memory nk, bool usdIs0) = _concentrateNvda(3_000e18);
        int24 nearEdge = usdIs0 ? int24(-590) : int24(590);
        extRouter.swap(nk, SwapParams(usdIs0, -1_000_000e18, TickMath.getSqrtPriceAtTick(nearEdge)), settings, "");
        feeds[0].set(1.0608e8, block.timestamp); // Chainlink agrees with the pool
        vm.warp(block.timestamp + 1 minutes);
        _refreshFeedsExcept(0);
        feeds[0].set(1.0608e8, block.timestamp);
        uint256 owedImd = token.owed(0);
        token.convert();
        assertEq(token.owed(0), owedImd, "not paid as IMD at once");
        assertEq(token.pendingConvert(1), 6e18, "skipped, retried next round");
        assertGt(token.failingSince(1), 0);
    }

    /// @dev Finding 5 (info): with a shallow IMD/USDG pool every possible purchase is dust, so the stock is skipped
    ///      (never "bought as dust while failing") and the 30-day rule applies cleanly.
    function test_final5_5_shallowImdPoolThresholdsAgree() public {
        PoolKey memory ik = _key(address(imd), address(usdg), 9000, 90);
        lp.modifyLiquidity(ik, ModifyLiquidityParams(-FULL_90, FULL_90, -9_600e18, 0), ""); // 400e18 left
        assertApproxEqRel(token.maxConvert(), 1e18, 0.01e18);
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 1 minutes);
        uint256[6] memory out = token.convert();
        assertEq(out[1], 0, "no dust purchase");
        assertGt(token.failingSince(1), 0);
        _attemptEvery6Days(36, 0);
        assertLt(token.pendingConvert(1), 6e18, "paid as IMD after 30 days of failing");
    }

    // ------------------------------------------------------------ what honeypot scanners simulate

    /// @dev Buy and then sell the whole balance through a plain third-party router (as GoPlus-style simulators do):
    ///      both succeed, and the only cost is the 4% hook fee on each side.
    function test_scanner_buyAndSellAllThroughThirdPartyRouter() public {
        PoolKey memory k = hook.poolKey(address(token));
        bool imdIs0 = Currency.unwrap(k.currency0) == address(imd);
        address scanner = makeAddr("scanner");
        imd.mint(scanner, 100e18);
        vm.startPrank(scanner);
        imd.approve(address(extRouter), type(uint256).max);
        token.approve(address(extRouter), type(uint256).max);
        uint256 imdBefore = imd.balanceOf(scanner);
        extRouter.swap(
            k,
            SwapParams(imdIs0, -10e18, imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        uint256 bought = token.balanceOf(scanner);
        assertGt(bought, 0, "can buy");
        extRouter.swap(
            k,
            SwapParams(!imdIs0, -int256(bought), !imdIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        vm.stopPrank();
        assertEq(token.balanceOf(scanner), 0, "can sell all");
        uint256 back = imd.balanceOf(scanner) - (imdBefore - 10e18);
        // round trip loses about 4% + 4% (plus a little price impact), nothing more
        assertApproxEqRel(back, 10e18 * 96 / 100 * 96 / 100, 0.01e18);
    }

    /// @dev Plain transfers work for any address, including to and from fresh wallets and contracts; nothing can
    ///      block, pause or tax a wallet-to-wallet transfer.
    function test_scanner_transfersAreUnrestricted() public {
        uint256 got = _buy(alice, 100e18);
        address fresh = makeAddr("fresh");
        address someContract = address(new MockERC20("x", "x"));
        vm.prank(alice);
        token.transfer(fresh, got / 2);
        assertEq(token.balanceOf(fresh), got / 2, "no transfer tax");
        vm.prank(fresh);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(fresh, someContract, got / 2);
        assertEq(token.balanceOf(someContract), got / 2);
        vm.prank(someContract);
        token.transfer(carol, got / 2);
        assertEq(token.balanceOf(carol), got / 2);
    }

    function test_ownership_renouncedAtDeployment() public {
        assertEq(token.owner(), address(0));
        // the deployer is recorded and then renounced, in the constructor
        vm.recordLogs();
        address[5] memory s;
        CompanyToken.Pool[5] memory pools;
        for (uint256 i; i < 5; i++) {
            s[i] = address(stocks[i]);
            pools[i] = CompanyToken.Pool(3000, 60);
        }
        CompanyToken t2 =
            new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools, _oracles());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("OwnershipTransferred(address,address)");
        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            address prev = address(uint160(uint256(logs[i].topics[1])));
            address next = address(uint160(uint256(logs[i].topics[2])));
            if (seen == 0) assertEq(prev, address(0));
            if (seen == 0) assertEq(next, address(this));
            if (seen == 1) assertEq(prev, address(this));
            if (seen == 1) assertEq(next, address(0));
            seen++;
        }
        assertEq(seen, 2);
        assertEq(t2.owner(), address(0));
    }

    // ------------------------------------------------------------ permit

    function test_permit_sellWithoutApprove() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        imd.mint(signer, 1_000e18);
        vm.prank(signer);
        imd.approve(address(router), type(uint256).max);
        uint256 got = _buy(signer, 100e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(token.PERMIT_TYPEHASH(), signer, address(router), got, 0, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(signer);
        router.sellWithPermit(address(token), got, 0, deadline, v, r, s);
        assertEq(token.balanceOf(signer), 0);
    }

    // ------------------------------------------------------------ solvency

    /// @dev Random trades, transfers, conversions, claims and time jumps: every asset stays fully backed and
    ///      what holders can withdraw never exceeds what is owed.
    function testFuzz_solvency(uint256 seed) public {
        address[3] memory us = [alice, bob, carol];
        for (uint256 step; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address u = us[seed % 3];
            uint256 op = (seed >> 8) % 6;
            uint256 amt = 1e18 + ((seed >> 16) % 5_000e18);
            if (op == 0) {
                _buy(u, amt);
            } else if (op == 1 && token.balanceOf(u) > 0) {
                _sell(u, token.balanceOf(u) / 2 + 1);
            } else if (op == 2 && token.balanceOf(u) > 0) {
                uint256 part = token.balanceOf(u) / 3;
                vm.prank(u);
                token.transfer(us[(seed >> 32) % 3], part);
            } else if (op == 3) {
                vm.warp(block.timestamp + 1 minutes + (seed >> 40) % 3 days);
                token.convert();
            } else if (op == 4) {
                vm.prank(u);
                token.claim();
            } else {
                token.recycle(u);
            }
            _assertSolvent(us);
        }
    }

    function _assertSolvent(address[3] memory us) internal view {
        assertEq(
            token.eligibleSupply(),
            token.weightOf(us[0]) + token.weightOf(us[1]) + token.weightOf(us[2]),
            "eligible = sum of weights"
        );
        address[6] memory a = token.assetList();
        uint256 pending;
        for (uint256 s = 1; s <= 5; s++) {
            pending += token.pendingConvert(s);
        }
        assertGe(imd.balanceOf(address(token)), token.owed(0) + pending + token.recycledHeld(0), "IMD backed");
        for (uint256 i; i < 6; i++) {
            if (i > 0) {
                assertGe(
                    MockERC20(a[i]).balanceOf(address(token)), token.owed(i) + token.recycledHeld(i), "stock backed"
                );
            }
            uint256 sum;
            for (uint256 j; j < 3; j++) {
                sum += token.withdrawableRewardOf(us[j], i);
            }
            assertLe(sum, token.owed(i), "withdrawable <= owed");
        }
    }
}
