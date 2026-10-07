// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CompanyHook} from "../src/CompanyHook.sol";
import {CompanyToken} from "../src/CompanyToken.sol";
import {CompanyConfig} from "./CompanyConfig.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Deploys $COMPANY: CompanyHook (at a mined CREATE2 address) and CompanyToken, then opens the pool when the
///         broadcasting account is the owner.
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --interactive
/// Optional env: OWNER (default: protocol address), START_MCAP (IMD wei, default 306e18 = $3,000 at IMD $9.80 on
/// 2026-10-07; set it from the IMD price on deploy day), SALT_START, RECORD.
contract Deploy is Script {
    function run() external {
        address owner = vm.envOr("OWNER", CompanyConfig.FEE_RECIPIENT);
        uint256 startMcap = vm.envOr("START_MCAP", uint256(306e18));

        bytes memory initCode = CompanyConfig.hookInitCode(owner, CompanyConfig.FEE_RECIPIENT, startMcap);
        (bytes32 salt, address expected) =
            DeployLib.mineSalt(CREATE2_FACTORY, CompanyConfig.HOOK_FLAGS, initCode, vm.envOr("SALT_START", uint256(0)));
        require(expected.code.length == 0, "already deployed at mined address");

        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && expected.code.length > 0, "hook deploy failed");
        CompanyHook hook = CompanyHook(payable(expected));
        CompanyToken token = CompanyConfig.deployToken(address(hook));
        bool opened = msg.sender == owner;
        if (opened) hook.openPool(address(token));
        vm.stopBroadcast();

        console.log("CompanyHook        :", address(hook));
        console.log("$COMPANY token     :", address(token));
        console.log("Router / ETH router:", hook.router(), hook.ethRouter());
        console.log("Pool opened        :", opened);

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || !vm.envOr("RECORD", true)) return;
        string memory json = "company";
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "router", hook.router());
        vm.serializeAddress(json, "ethRouter", hook.ethRouter());
        vm.serializeAddress(json, "owner", owner);
        vm.serializeUint(json, "startMarketCapImd", startMcap);
        string memory out = vm.serializeBool(json, "poolOpened", opened);
        vm.writeJson(out, "./deployments/robinhood.json");
    }
}
