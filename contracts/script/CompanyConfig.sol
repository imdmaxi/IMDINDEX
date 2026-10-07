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
    address internal constant AMC = 0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B;
    address internal constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;

    uint160 internal constant HOOK_FLAGS = 0x28CC;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    /// @dev Pools (all hookless), by v4 pool id:
    ///   IMD/ETH    0xd2fc01ee…8f02  fee 1%     spacing 100  (ETH router)
    ///   IMD/USDG   0xaf5bcd88…406f  fee 0.9%   spacing 90
    ///   USDG/NVDA  0x6444a8e0…29c5  fee 0.01%  spacing 1
    ///   GOOGL/USDG 0xd4ecb79f…ac5e  fee 0.3%   spacing 60
    ///   USDG/AAPL  0xc748f467…8fdb  fee 0.3%   spacing 60
    ///   AMC/USDG   0x7499938c…1d9d  fee 0.1%   spacing 10
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
        address[5] memory stocks = [NVDA, GOOGL, AAPL, AMC, MSTR];
        CompanyToken.Pool[5] memory pools = [
            CompanyToken.Pool(100, 1),
            CompanyToken.Pool(3000, 60),
            CompanyToken.Pool(3000, 60),
            CompanyToken.Pool(1000, 10),
            CompanyToken.Pool(2500, 25)
        ];
        return new CompanyToken(hook, USDG, CompanyToken.Pool(9000, 90), stocks, pools);
    }
}
