// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Builds Merkle roots and proofs that OpenZeppelin's `MerkleProof` accepts.
/// @dev Tests only. Inner nodes hash the two children in sorted order (commutative keccak256),
///      exactly as `MerkleProof.verify` expects. Each level pairs neighbours from left to right;
///      an odd node at the end of a level moves up unchanged.
///
///      This builder is simpler than OpenZeppelin's StandardMerkleTree (which also sorts the
///      leaves), but both produce proofs that the same verifier accepts.
library MerkleTreeBuilder {
    /// @notice Root of the tree over `leaves`. A single leaf is its own root.
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "MerkleTreeBuilder: no leaves");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    /// @notice Proof for `leaves[index]`: the sibling hashes from the leaf up to the root.
    function proof(bytes32[] memory leaves, uint256 index)
        internal
        pure
        returns (bytes32[] memory siblings)
    {
        require(index < leaves.length, "MerkleTreeBuilder: index out of range");

        // A tree with up to 2^256 leaves has at most 256 levels.
        bytes32[] memory buffer = new bytes32[](256);
        uint256 count;

        bytes32[] memory level = leaves;
        while (level.length > 1) {
            // The sibling is the other node of the pair. A node without a pair has no sibling
            // at this level and adds nothing to the proof.
            uint256 sibling = index ^ 1;
            if (sibling < level.length) buffer[count++] = level[sibling];
            index /= 2;
            level = _nextLevel(level);
        }

        siblings = new bytes32[](count);
        for (uint256 i; i < count; i++) {
            siblings[i] = buffer[i];
        }
    }

    function _nextLevel(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < level.length / 2; i++) {
            next[i] = _hashPair(level[2 * i], level[2 * i + 1]);
        }
        if (level.length % 2 == 1) next[next.length - 1] = level[level.length - 1];
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
