// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";

import {MORCastEscrow} from "../src/MORCastEscrow.sol";

/// @notice Deploys MORCastEscrow.
/// @dev Environment variables:
///
///        OWNER     owner of the escrow. Should be a multisig          (required)
///        SETTLER   the address allowed to settle campaigns            (required)
///        TREASURY  the address that receives protocol fees            (required)
///        USDC      USDC token address        (required, except on Base mainnet)
///        MOR       MOR token address         (required, except on Base mainnet)
///
///      On Base mainnet (chain ID 8453) the canonical USDC and MOR addresses are always used.
///      If USDC or MOR is set there, it must equal the canonical address, so a wrong token can
///      never be deployed by mistake.
///
///      Usage:
///        forge script script/Deploy.s.sol --rpc-url <rpc> --account <keystore> --broadcast --verify
contract Deploy is Script {
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;

    /// @dev Circle-issued USDC on Base (6 decimals). Not the bridged USDbC.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Morpheus MOR on Base (18 decimals).
    address public constant BASE_MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    function run() external returns (MORCastEscrow escrow) {
        address owner = vm.envAddress("OWNER");
        address settler = vm.envAddress("SETTLER");
        address treasury = vm.envAddress("TREASURY");
        (address usdc, address mor) =
            resolveTokens(block.chainid, vm.envOr("USDC", address(0)), vm.envOr("MOR", address(0)));

        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = mor;

        vm.startBroadcast();
        escrow = new MORCastEscrow(owner, settler, treasury, tokens);
        vm.stopBroadcast();

        console.log("Chain ID     ", block.chainid);
        console.log("MORCastEscrow", address(escrow));
        console.log("OWNER        ", owner);
        console.log("SETTLER      ", settler);
        console.log("TREASURY     ", treasury);
        console.log("USDC         ", usdc);
        console.log("MOR          ", mor);
    }

    /// @notice Token addresses to deploy with on `chainId`, given the configured addresses
    ///         (zero when not configured).
    /// @dev On Base mainnet the canonical tokens are always used. A configured address must
    ///      equal the canonical one. On every other chain both addresses must be configured.
    function resolveTokens(uint256 chainId, address usdc, address mor)
        public
        pure
        returns (address, address)
    {
        if (chainId == BASE_MAINNET_CHAIN_ID) {
            require(usdc == address(0) || usdc == BASE_USDC, "Deploy: USDC must be canonical");
            require(mor == address(0) || mor == BASE_MOR, "Deploy: MOR must be canonical");
            return (BASE_USDC, BASE_MOR);
        }
        require(usdc != address(0) && mor != address(0), "Deploy: USDC and MOR are required");
        return (usdc, mor);
    }
}
