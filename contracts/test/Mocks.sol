// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    /// @dev Simulates a balance dropping outside a transfer (e.g. a reverse split).
    function slash(address who, uint256 amt) external {
        balanceOf[who] -= amt;
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        _move(f, to, amt);
        return true;
    }

    function _move(address f, address to, uint256 amt) internal virtual {
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Stands in for a Robinhood stock token: a per-address blocklist checked on sender, receiver and caller.
contract MockStock is MockERC20 {
    error Blocked();

    mapping(address => bool) public blocked;

    constructor(string memory symbol_) MockERC20(string.concat(symbol_, " Robinhood Token"), symbol_) {}

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _move(address f, address to, uint256 amt) internal override {
        if (blocked[f] || blocked[to] || blocked[msg.sender]) revert Blocked();
        super._move(f, to, amt);
    }
}
