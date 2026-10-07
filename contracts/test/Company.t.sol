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
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {CompanyHook} from "../src/CompanyHook.sol";
import {CompanyToken} from "../src/CompanyToken.sol";
import {CompanyRouter} from "../src/CompanyRouter.sol";
import {CompanyEthRouter} from "../src/CompanyEthRouter.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockERC20, MockStock} from "./Mocks.sol";

/// @notice Borrows the pool's $COMPANY inside an unlock, then tries to distribute, convert or claim with it.
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
        string[5] memory names = ["NVDA", "GOOGL", "AAPL", "AMC", "MSTR"];
        for (uint256 i; i < 5; i++) {
            stocks[i] = new MockStock(names[i]);
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

        token = new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), stockAddrs, pools);
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
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(3000, 60), s, pools);
        pools[2] = CompanyToken.Pool(500, 10);
        vm.expectRevert(CompanyToken.BadPool.selector);
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools);
        pools[2] = CompanyToken.Pool(3000, 60);
        s[4] = s[0];
        vm.expectRevert(CompanyToken.BadAsset.selector);
        new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools);
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
        uint256 cap = token.maxConvert() / 5; // 25 IMD per round, shared by five stocks
        uint256[6] memory out = token.convert();
        // 5 IMD -> ~4.955 USDG (0.9%) -> ~4.94 NVDA (0.3%), small price impact
        assertApproxEqRel(out[1], 4.94e18, 0.01e18);
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
        assertApproxEqRel(token.maxConvert(), 25e18, 0.01e18);

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

    function test_stuckStock_skippedByClaim_releasedToImdAfter30Days() public {
        _buy(alice, 1_000e18);
        _buy(bob, 1_000e18);
        _stock(4).setBlocked(address(token), true); // AMC refuses the token contract
        vm.warp(block.timestamp + 1 minutes);
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        assertEq(paid[4], 0, "AMC skipped");
        assertEq(token.pendingConvert(4), 6e18, "AMC reserve untouched");
        assertGt(paid[1], 0, "other stocks converted and paid");

        vm.expectRevert(CompanyToken.TooSoon.selector);
        token.releaseStuckReserve(4);
        vm.warp(block.timestamp + 30 days);
        uint256 owedBefore = token.owed(0);
        uint256 amount = token.releaseStuckReserve(4);
        assertEq(amount, 6e18);
        assertEq(token.pendingConvert(4), 0);
        assertEq(token.owed(0), owedBefore + 6e18);
    }

    function test_releaseStuckReserve_notWhileConverting() public {
        _buy(alice, 1_000e18);
        for (uint256 d; d < 31; d++) {
            vm.warp(block.timestamp + 1 days);
            _buy(bob, 1_000e18);
            token.convert();
        }
        _buy(bob, 1_000e18);
        vm.expectRevert(CompanyToken.TooSoon.selector);
        token.releaseStuckReserve(1);
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

    function test_expiry_giftDoesNotResetTimer_buyDoes() public {
        _buy(alice, 1_000e18);
        uint256 got = _buy(bob, 1_000e18);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        token.transfer(alice, got / 2);
        assertGt(token.expiredRewardsOf(alice, 0), 0, "gift is not activity");
        _buy(alice, 1e18);
        assertEq(token.expiredRewardsOf(alice, 0), 0, "buy is activity");
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
        CompanyToken t2 = new CompanyToken(address(hook), address(usdg), CompanyToken.Pool(9000, 90), s, pools);
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
        assertGe(imd.balanceOf(address(token)), token.owed(0) + pending, "IMD backed");
        for (uint256 i; i < 6; i++) {
            if (i > 0) assertGe(MockERC20(a[i]).balanceOf(address(token)), token.owed(i), "stock backed");
            uint256 sum;
            for (uint256 j; j < 3; j++) {
                sum += token.withdrawableRewardOf(us[j], i);
            }
            assertLe(sum, token.owed(i), "withdrawable <= owed");
        }
    }
}
