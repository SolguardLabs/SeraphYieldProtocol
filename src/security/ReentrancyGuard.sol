// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal single-slot reentrancy protection for state-changing entry points.
abstract contract ReentrancyGuard {
    error ReentrantCall();

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _reentrancyStatus = _NOT_ENTERED;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    function _reentrancyEntered() internal view returns (bool) {
        return _reentrancyStatus == _ENTERED;
    }
}
