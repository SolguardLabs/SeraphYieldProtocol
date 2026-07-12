// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20, IERC20Permit } from "./IERC20.sol";

/// @notice Share token interface consumed by vault accounting modules.
interface ISeraphShare is IERC20, IERC20Permit {
    function vault() external view returns (address);
    function transferHook() external view returns (address);
    function totalLocked() external view returns (uint256);
    function lockedBalanceOf(address account) external view returns (uint256);
    function activeBalanceOf(address account) external view returns (uint256);
    function activeSupply() external view returns (uint256);

    function mint(address receiver, uint256 shares) external;
    function burn(address owner, uint256 shares) external;
    function lock(address owner, uint256 shares) external;
    function unlock(address owner, uint256 shares) external;
    function burnLocked(address owner, uint256 shares) external;
    function setQueue(address newQueue) external;
    function setTransferHook(address newHook) external;
}
