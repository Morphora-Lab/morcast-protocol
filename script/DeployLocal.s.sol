// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";

import {MorcastEscrow} from "../src/MorcastEscrow.sol";
import {MockERC20} from "../test/utils/Tokens.sol";

/// @notice Deploys mock USDC and MOR tokens and an escrow that accepts them, for local
///         development against Anvil. Never use it on a public network.
/// @dev Environment variables (all optional):
///
///        OWNER     escrow owner         (default: Anvil account 0, the deployer)
///        SETTLER   settlement address   (default: Anvil account 1)
///        TREASURY  fee recipient        (default: Anvil account 2)
///        BRAND     account that receives 1,000,000 mock USDC and MOR (default: Anvil account 3)
///
///      Usage:
///        anvil
///        forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///          --private-key <anvil account 0 key> --broadcast
contract DeployLocal is Script {
    /// @dev Default Anvil accounts derived from the "test test ... junk" mnemonic.
    address internal constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant ANVIL_ACCOUNT_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    function run() external returns (MorcastEscrow escrow, MockERC20 usdc, MockERC20 mor) {
        require(block.chainid == 31_337, "DeployLocal: Anvil only");

        address owner = vm.envOr("OWNER", ANVIL_ACCOUNT_0);
        address settler = vm.envOr("SETTLER", ANVIL_ACCOUNT_1);
        address treasury = vm.envOr("TREASURY", ANVIL_ACCOUNT_2);
        address brand = vm.envOr("BRAND", ANVIL_ACCOUNT_3);

        vm.startBroadcast();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mor = new MockERC20("MorpheusAI", "MOR", 18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(mor);
        escrow = new MorcastEscrow(owner, settler, treasury, tokens);
        usdc.mint(brand, 1_000_000e6);
        mor.mint(brand, 1_000_000e18);
        vm.stopBroadcast();

        console.log("MorcastEscrow", address(escrow));
        console.log("USDC (mock)  ", address(usdc));
        console.log("MOR (mock)   ", address(mor));
        console.log("OWNER        ", owner);
        console.log("SETTLER      ", settler);
        console.log("TREASURY     ", treasury);
        console.log("BRAND        ", brand);
    }
}
