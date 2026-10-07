// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CompanyHook} from "../src/CompanyHook.sol";
import {CompanyToken} from "../src/CompanyToken.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Robinhood Chain (4663) mainnet addresses and pools used by $COMPANY, shared by the deploy script and the
///         fork test. Checked on-chain on 2026-10-07: token symbols, the stock tokens' shared Robinhood beacon, and
///         every pool id against PositionManager.poolKeys and StateView.
library CompanyConfig {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @notice Protocol fee recipient (also receives expired rewards).
    address internal constant FEE_RECIPIENT = 0x8F5A29c82e8285Db3B2af8D0caF5404b0f9ce834;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address internal constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;

    /// @dev Chainlink feeds on Robinhood Chain (8 decimals), from Chainlink's directory and checked on-chain
    ///      (description and latest answer) on 2026-10-07.
    address internal constant USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address internal constant NVDA_USD = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant GOOGL_USD = 0xF6f373a037c30F0e5010d854385cA89185AE638b;
    address internal constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address internal constant GME_USD = 0x27C71df6A64fB476468EdF256CF72c038baB5B67;
    address internal constant MSTR_USD = 0x396118bdFB181e6240E74D243F266B061c0edc3D;

    uint160 internal constant HOOK_FLAGS = 0x28CC;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    /// @dev Pools (all hookless), by v4 pool id:
    ///   IMD/ETH    0xd2fc01ee…8f02  fee 1%     spacing 100  (ETH router)
    ///   IMD/USDG   0xaf5bcd88…406f  fee 0.9%   spacing 90
    ///   USDG/NVDA  0x6444a8e0…29c5  fee 0.01%  spacing 1
    ///   GOOGL/USDG 0xd4ecb79f…ac5e  fee 0.3%   spacing 60
    ///   USDG/AAPL  0xc748f467…8fdb  fee 0.3%   spacing 60
    ///   GME/USDG   0x3d436b4f…063b  fee 1%     spacing 200
    ///   USDG/MSTR  0x319bac87…7cfe  fee 0.25%  spacing 25
    function hookInitCode(address owner, address feeRecipient, uint256 startMarketCapImd)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(CompanyHook).creationCode,
            abi.encode(
                POOL_MANAGER,
                IMD,
                owner,
                feeRecipient,
                DeployLib.startTickForMarketCap(startMarketCapImd, SUPPLY),
                CompanyHook.ImdEthPool({fee: 10_000, tickSpacing: 100, hooks: address(0)})
            )
        );
    }

    function deployToken(address hook) internal returns (CompanyToken) {
        address[5] memory stocks = [NVDA, GOOGL, AAPL, GME, MSTR];
        CompanyToken.Pool[5] memory pools = [
            CompanyToken.Pool(100, 1),
            CompanyToken.Pool(3000, 60),
            CompanyToken.Pool(3000, 60),
            CompanyToken.Pool(10_000, 200),
            CompanyToken.Pool(2500, 25)
        ];
        address[5] memory feeds = [NVDA_USD, GOOGL_USD, AAPL_USD, GME_USD, MSTR_USD];
        return new CompanyToken(hook, USDG, CompanyToken.Pool(9000, 90), stocks, pools, USDG_USD, feeds);
    }
}
