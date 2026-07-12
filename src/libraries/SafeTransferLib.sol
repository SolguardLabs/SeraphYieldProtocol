// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @notice Defensive wrappers for ERC-20 and native asset operations.
/// @dev Supports tokens that return true as well as tokens that return no data.
library SafeTransferLib {
    error TransferFailed(address token, address to, uint256 amount);
    error TransferFromFailed(address token, address from, address to, uint256 amount);
    error ApprovalFailed(address token, address spender, uint256 amount);
    error BalanceQueryFailed(address token, address account);
    error AllowanceQueryFailed(address token, address owner, address spender);
    error NativeTransferFailed(address to, uint256 amount);

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!_returnedTrue(success, returnData)) {
            revert TransferFailed(address(token), to, amount);
        }
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory returnData) = address(token)
            .call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!_returnedTrue(success, returnData)) {
            revert TransferFromFailed(address(token), from, to, amount);
        }
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!_returnedTrue(success, returnData)) {
            revert ApprovalFailed(address(token), spender, amount);
        }
    }

    /// @notice Sets an allowance, retrying through zero for tokens that require it.
    function forceApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (_returnedTrue(success, returnData)) return;

        (success, returnData) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!_returnedTrue(success, returnData)) {
            revert ApprovalFailed(address(token), spender, 0);
        }

        (success, returnData) =
            address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!_returnedTrue(success, returnData)) {
            revert ApprovalFailed(address(token), spender, amount);
        }
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 increase) internal {
        uint256 current = safeAllowance(token, address(this), spender);
        uint256 updated = current + increase;
        forceApprove(token, spender, updated);
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 decrease) internal {
        uint256 current = safeAllowance(token, address(this), spender);
        if (decrease > current) revert ApprovalFailed(address(token), spender, 0);
        unchecked {
            forceApprove(token, spender, current - decrease);
        }
    }

    function safeBalanceOf(IERC20 token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory returnData) =
            address(token).staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, account));
        if (!success || returnData.length < 32) {
            revert BalanceQueryFailed(address(token), account);
        }
        balance = abi.decode(returnData, (uint256));
    }

    function safeAllowance(IERC20 token, address owner, address spender)
        internal
        view
        returns (uint256 value)
    {
        (bool success, bytes memory returnData) = address(token)
            .staticcall(abi.encodeWithSelector(IERC20.allowance.selector, owner, spender));
        if (!success || returnData.length < 32) {
            revert AllowanceQueryFailed(address(token), owner, spender);
        }
        value = abi.decode(returnData, (uint256));
    }

    function safeTransferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert NativeTransferFailed(to, amount);
    }

    function _returnedTrue(bool success, bytes memory returnData) private pure returns (bool) {
        if (!success) return false;
        if (returnData.length == 0) return true;
        if (returnData.length < 32) return false;

        uint256 returnedValue;
        assembly ("memory-safe") {
            returnedValue := mload(add(returnData, 0x20))
        }
        return returnedValue == 1;
    }
}
