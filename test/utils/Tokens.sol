// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 with configurable decimals and public minting, used as USDC and MOR in
///         tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC-20 that burns 1% of every transfer between two accounts. The recipient receives
///         less than the amount sent, which the escrow must detect at deposit.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        // Minting and burning are not charged.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice ERC-20 that calls back into a target contract the first time it transfers tokens
///         out of that contract. Used to prove that the escrow's reentrancy guard blocks nested
///         calls from a token.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public callbackData;
    bool private _armed;

    constructor() MockERC20("Reentrant Token", "REENTER", 18) {}

    /// @notice Arms a single callback: the next transfer out of `target_` calls `target_` with
    ///         `data_`. A failed callback reverts the transfer with the callback's error.
    function arm(address target_, bytes calldata data_) external {
        target = target_;
        callbackData = data_;
        _armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (_armed && from == target) {
            _armed = false;
            (bool ok, bytes memory reason) = target.call(callbackData);
            if (!ok) {
                // Bubble up the revert reason of the nested call.
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}
