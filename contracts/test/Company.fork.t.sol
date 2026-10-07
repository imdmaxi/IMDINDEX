// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {CompanyHook} from "../src/CompanyHook.sol";
import {CompanyToken} from "../src/CompanyToken.sol";
import {CompanyRouter} from "../src/CompanyRouter.sol";
import {CompanyEthRouter} from "../src/CompanyEthRouter.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {CompanyConfig} from "../script/CompanyConfig.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Deploys $COMPANY on a fork of Robinhood Chain and runs it against the real IMD, USDG, stock tokens and
///         Uniswap v4 pools: trade, then one claim that converts into every stock and pays out.
///   FORK_RPC=https://robinhood.drpc.org forge test --mc CompanyForkTest -vv
contract CompanyForkTest is Test {
    CompanyHook hook;
    CompanyToken token;
    CompanyRouter router;
    CompanyEthRouter ethRouter;
    bool forked;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        address owner = makeAddr("owner");
        bytes memory initCode = CompanyConfig.hookInitCode(owner, CompanyConfig.FEE_RECIPIENT, 306e18);
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), CompanyConfig.HOOK_FLAGS, initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        hook = CompanyHook(payable(deployed));
        router = CompanyRouter(payable(hook.router()));
        ethRouter = CompanyEthRouter(payable(hook.ethRouter()));
        token = CompanyConfig.deployToken(address(hook));
        vm.prank(owner);
        hook.openPool(address(token));

        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; i++) {
            vm.deal(users[i], 100 ether);
            vm.prank(users[i]);
            IERC20(CompanyConfig.IMD).approve(address(router), type(uint256).max);
        }
    }

    function test_fork_tradeConvertClaim() public {
        if (!forked) return;
        // buy with ETH through the real IMD/ETH pool, so no IMD balance has to be faked
        vm.prank(alice);
        ethRouter.buyWithEth{value: 1 ether}(address(token), 0, block.timestamp);
        vm.prank(bob);
        ethRouter.buyWithEth{value: 20 ether}(address(token), 0, block.timestamp);
        assertGt(token.owed(0), 0, "IMD credited");
        console.log("IMD credited to holders  :", token.owed(0));
        console.log("IMD reserved per stock   :", token.pendingConvert(1));
        console.log("max IMD per conversion   :", token.maxConvert());

        vm.warp(block.timestamp + 1 minutes);
        string[6] memory names = ["IMD", "NVDA", "GOOGL", "AAPL", "AMC", "MSTR"];
        uint256[6] memory before;
        for (uint256 s = 1; s <= 5; s++) {
            before[s] = token.pendingConvert(s);
        }

        // one claim converts every stock's reserve and pays all six assets
        vm.prank(alice);
        uint256[6] memory paid = token.claim();
        address[6] memory a = token.assetList();
        for (uint256 s; s < 6; s++) {
            assertGt(paid[s], 0, names[s]);
            assertEq(IERC20(a[s]).balanceOf(alice), paid[s]);
            console.log(names[s], "paid to alice:", paid[s]);
            if (s > 0) assertLt(token.pendingConvert(s), before[s], "converted");
        }
    }
}
