// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Arithmetic helpers with explicit rounding behavior.
library MathLib {
    error DivisionByZero();
    error MulDivOverflow();
    error MathOverflow();
    error CastOverflow();
    error InvalidBounds();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 value, uint256 lower, uint256 upper) internal pure returns (uint256) {
        if (lower > upper) revert InvalidBounds();
        return min(max(value, lower), upper);
    }

    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a & b) + ((a ^ b) >> 1);
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }

    /// @notice Calculates floor(x * y / denominator) with full 512-bit precision.
    function mulDivDown(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            uint256 productLow;
            uint256 productHigh;

            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                productLow := mul(x, y)
                productHigh := sub(sub(mm, productLow), lt(mm, productLow))
            }

            if (productHigh == 0) {
                if (denominator == 0) revert DivisionByZero();
                return productLow / denominator;
            }

            if (denominator <= productHigh) revert MulDivOverflow();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                productHigh := sub(productHigh, gt(remainder, productLow))
                productLow := sub(productLow, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                productLow := div(productLow, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            productLow |= productHigh * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = productLow * inverse;
        }
    }

    /// @notice Calculates ceil(x * y / denominator) with full 512-bit precision.
    function mulDivUp(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDivDown(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) revert MathOverflow();
            unchecked {
                ++result;
            }
        }
    }

    function wadMulDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, y, WAD);
    }

    function wadMulUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD);
    }

    function wadDivDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivDown(x, WAD, y);
    }

    function wadDivUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    function bpsMulDown(uint256 value, uint256 bps) internal pure returns (uint256) {
        return mulDivDown(value, bps, BPS);
    }

    function bpsMulUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        return mulDivUp(value, bps, BPS);
    }

    function ratioBps(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return numerator == 0 ? 0 : BPS;
        return mulDivDown(numerator, BPS, denominator);
    }

    /// @notice Integer square root, rounded down.
    function sqrt(uint256 value) internal pure returns (uint256 result) {
        if (value == 0) return 0;

        result = 2 ** (log2(value) >> 1);
        unchecked {
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            result = (result + value / result) >> 1;
            return min(result, value / result);
        }
    }

    /// @notice Binary logarithm, rounded down.
    function log2(uint256 value) internal pure returns (uint256 result) {
        unchecked {
            if (value >> 128 != 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 != 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 != 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 != 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 != 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 != 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 != 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 != 0) result += 1;
        }
    }

    function toUint128(uint256 value) internal pure returns (uint128 result) {
        if (value > type(uint128).max) revert CastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint128(value);
    }

    function toUint96(uint256 value) internal pure returns (uint96 result) {
        if (value > type(uint96).max) revert CastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint96(value);
    }

    function toUint40(uint256 value) internal pure returns (uint40 result) {
        if (value > type(uint40).max) revert CastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint40(value);
    }

    function toUint32(uint256 value) internal pure returns (uint32 result) {
        if (value > type(uint32).max) revert CastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint32(value);
    }

    function toUint16(uint256 value) internal pure returns (uint16 result) {
        if (value > type(uint16).max) revert CastOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        result = uint16(value);
    }
}
