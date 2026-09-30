// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {DeployLocal} from "../../script/DeployLocal.s.sol";
import {MORCastEscrow} from "../../src/MORCastEscrow.sol";
import {MockERC20} from "../utils/Tokens.sol";

/// @notice Tests for the deployment scripts.
contract DeployTest is Test {
    Deploy internal deployer = new Deploy();

    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    // -------------------------------------------------------------------------------------------
    // Deploy.resolveTokens
    // -------------------------------------------------------------------------------------------

    function test_resolveTokens_defaultsToCanonicalTokensOnBase() public view {
        (address usdc, address mor) = deployer.resolveTokens(8453, address(0), address(0));
        assertEq(usdc, BASE_USDC);
        assertEq(mor, BASE_MOR);
    }

    function test_resolveTokens_acceptsCanonicalOverridesOnBase() public view {
        (address usdc, address mor) = deployer.resolveTokens(8453, BASE_USDC, BASE_MOR);
        assertEq(usdc, BASE_USDC);
        assertEq(mor, BASE_MOR);
    }

    function test_resolveTokens_rejectsOtherTokensOnBase() public {
        vm.expectRevert("Deploy: USDC must be canonical");
        deployer.resolveTokens(8453, address(0xBAD), address(0));

        vm.expectRevert("Deploy: MOR must be canonical");
        deployer.resolveTokens(8453, address(0), address(0xBAD));
    }

    function test_resolveTokens_usesConfiguredTokensElsewhere() public view {
        (address usdc, address mor) = deployer.resolveTokens(84_532, address(0xA), address(0xB));
        assertEq(usdc, address(0xA));
        assertEq(mor, address(0xB));
    }

    function test_resolveTokens_requiresBothTokensElsewhere() public {
        vm.expectRevert("Deploy: USDC and MOR are required");
        deployer.resolveTokens(84_532, address(0xA), address(0));
    }

    // -------------------------------------------------------------------------------------------
    // Deploy.run
    // -------------------------------------------------------------------------------------------

    /// @notice The only test that sets environment variables, so parallel tests are unaffected.
    function test_run_deploysEscrowFromEnvironment() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 mor = new MockERC20("MorpheusAI", "MOR", 18);
        vm.setEnv("SETTLER", vm.toString(address(0x5E77)));
        vm.setEnv("TREASURY", vm.toString(address(0x7EA5)));
        vm.setEnv("USDC", vm.toString(address(usdc)));
        vm.setEnv("MOR", vm.toString(address(mor)));

        MORCastEscrow escrow = deployer.run();

        assertEq(escrow.SETTLER(), address(0x5E77));
        assertEq(escrow.TREASURY(), address(0x7EA5));
        assertEq(escrow.USDC(), address(usdc));
        assertEq(escrow.MOR(), address(mor));
    }

    // -------------------------------------------------------------------------------------------
    // DeployLocal.run
    // -------------------------------------------------------------------------------------------

    function test_deployLocal_deploysMocksAndFundsBrand() public {
        (MORCastEscrow escrow, MockERC20 usdc, MockERC20 mor) = new DeployLocal().run();

        assertEq(escrow.USDC(), address(usdc));
        assertEq(escrow.MOR(), address(mor));
        assertEq(usdc.decimals(), 6);
        assertEq(mor.decimals(), 18);
        assertEq(usdc.totalSupply(), 1_000_000e6);
        assertEq(mor.totalSupply(), 1_000_000e18);
    }

    function test_deployLocal_refusesPublicNetworks() public {
        DeployLocal script = new DeployLocal();
        vm.chainId(8453);
        vm.expectRevert("DeployLocal: Anvil only");
        script.run();
    }
}
