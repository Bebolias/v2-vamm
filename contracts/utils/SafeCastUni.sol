// SPDX-License-Identifier: BUSL-1.1
// With contributions from OpenZeppelin Contracts v4.4.0 (utils/math/SafeCast.sol)

pragma solidity >=0.8.13;

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCastUni {
    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type uint160
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y, "toUint160 oflo");
    }

    /// @notice Cast a uint256 to a uint128, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type uint128
    function toUint128(uint256 y) internal pure returns (uint128 z) {
        require((z = uint128(y)) == y, "toUint128 oflo");
    }

    /// @notice Cast a int256 to a uint128, revert on overflow
    /// @param y The int256 to be downcasted
    /// @return z The downcasted integer, now type uint128
    function toUint128(int256 y) internal pure returns (uint128 z) {
        z = toUint128(toUint256(y));
    }

    /// @notice Cast a int256 to a int128, revert on overflow or underflow
    /// @param y The int256 to be downcasted
    /// @return z The downcasted integer, now type int128
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y, "toInt128 oflo");
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2**255, "toInt256 oflo");
        z = int256(y);
    }

    /// @notice Cast a uint256 to a int128, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int128
    function toInt128(uint256 y) internal pure returns (int128 z) {
        require(y < 2**127, "toInt128 oflo");
        z = int128(toUint128(y));
    }

    /// @dev Converts a signed int256 into an unsigned uint256.
    /// @param value must be greater than or equal to 0.
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "toUint256 < 0");
        return uint256(value);
    }
}
