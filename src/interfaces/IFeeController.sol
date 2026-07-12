// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { FeeConfig } from "../types/SeraphTypes.sol";

/// @notice Fee quotation interface used by the vault.
interface IFeeController {
    function feeConfig() external view returns (FeeConfig memory);
    function recipient() external view returns (address);
    function performanceFee(uint256 gain) external view returns (uint256);
    function withdrawalFee(uint256 assets) external view returns (uint256);
    function managementFee(uint256 totalAssets) external view returns (uint256);
    function checkpointManagementFee(uint256 totalAssets) external returns (uint256 feeAssets);
}
