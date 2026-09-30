// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {EscrowFixture} from "./utils/EscrowFixture.sol";

/// @notice Checks that the contract agrees with the off-chain implementation on hashing and on
///         payout trees, using vector files generated off-chain.
contract SharedVectorsTest is EscrowFixture {
    string internal constant CANONICAL = "/vectors/canonical.json";
    string internal constant MERKLE = "/vectors/merkle.json";

    /// @notice keccak256 of each canonical JSON text equals the hash in the vector file, so the
    ///         document hashes computed off-chain are the ones the chain would compute.
    function test_canonicalHashes_matchKeccak() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), CANONICAL));

        uint256 count;
        while (vm.keyExistsJson(json, _at(".cases", count, ""))) {
            string memory canonical = vm.parseJsonString(json, _at(".cases", count, ".canonical"));
            bytes32 expected = vm.parseJsonBytes32(json, _at(".cases", count, ".hash"));
            assertEq(
                keccak256(bytes(canonical)),
                expected,
                vm.parseJsonString(json, _at(".cases", count, ".name"))
            );
            count++;
        }
        assertGt(count, 0, "no vectors loaded");
    }

    /// @notice Every leaf of every off-chain tree hashes like `leafHash` and is proven against its
    ///         root by OpenZeppelin's MerkleProof, as `claim` does.
    function test_payoutTrees_areAcceptedByContract() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), MERKLE));

        uint256 cases;
        while (vm.keyExistsJson(json, _at(".cases", cases, ""))) {
            string memory c = _at(".cases", cases, "");
            uint256 id = vm.parseJsonUint(json, string.concat(c, ".campaignId"));
            bytes32 root = vm.parseJsonBytes32(json, string.concat(c, ".root"));

            uint256 leaves;
            while (vm.keyExistsJson(json, _at(string.concat(c, ".leaves"), leaves, ""))) {
                string memory l = _at(string.concat(c, ".leaves"), leaves, "");
                address wallet = vm.parseJsonAddress(json, string.concat(l, ".wallet"));
                uint256 amount = vm.parseJsonUint(json, string.concat(l, ".amount"));
                bytes32 leaf = vm.parseJsonBytes32(json, string.concat(l, ".leaf"));
                bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(l, ".proof"));

                assertEq(escrow.leafHash(id, wallet, amount), leaf, "leaf hash");
                assertTrue(MerkleProof.verify(proof, root, leaf), "proof");
                leaves++;
            }
            assertGt(leaves, 0, "case without leaves");
            cases++;
        }
        assertGt(cases, 0, "no vectors loaded");
    }

    /// @notice End to end: the partial-delivery tree built off-chain settles campaign 1, and every
    ///         creator claims its payout with the off-chain proof.
    function test_offChainTree_settlesAndPaysCampaign() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), MERKLE));
        string memory c = ".cases[0]";
        assertEq(vm.parseJsonString(json, string.concat(c, ".name")), "spec-13-partial-delivery");

        uint256 id = _createCampaign(); // campaign 1: 100,000 USDC, target 1,000,000
        assertEq(id, vm.parseJsonUint(json, string.concat(c, ".campaignId")));
        _settle(id, 640_000, vm.parseJsonBytes32(json, string.concat(c, ".root")));

        uint256 claimedTotal;
        for (uint256 i; vm.keyExistsJson(json, _at(string.concat(c, ".leaves"), i, "")); i++) {
            string memory l = _at(string.concat(c, ".leaves"), i, "");
            address wallet = vm.parseJsonAddress(json, string.concat(l, ".wallet"));
            uint256 amount = vm.parseJsonUint(json, string.concat(l, ".amount"));

            escrow.claim(
                id, wallet, amount, vm.parseJsonBytes32Array(json, string.concat(l, ".proof"))
            );
            assertEq(usdc.balanceOf(wallet), amount);
            claimedTotal += amount;
        }

        // The off-chain payouts exhaust the on-chain pool exactly.
        assertEq(claimedTotal, escrow.getCampaign(id).pool);
        assertEq(escrow.getCampaign(id).creatorClaimed, escrow.getCampaign(id).pool);
    }

    /// @dev JSON path of element `index` of the array at `path`, followed by `field`.
    function _at(string memory path, uint256 index, string memory field)
        private
        pure
        returns (string memory)
    {
        return string.concat(path, "[", vm.toString(index), "]", field);
    }
}
