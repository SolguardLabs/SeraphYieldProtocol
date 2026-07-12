// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RebalanceInstruction, StrategyConfig, StrategyState } from "../types/SeraphTypes.sol";

/// @notice Strategy registry, allocation and debt accounting used by a Seraph vault.
interface IStrategyRouter {
    struct HarvestSummary {
        uint256 gain;
        uint256 loss;
        uint256 debtPayment;
        uint256 strategiesReported;
    }

    function asset() external view returns (address);
    function vault() external view returns (address);
    function totalDebt() external view returns (uint256);
    function strategyCount() external view returns (uint256);
    function strategyAt(uint256 index) external view returns (address);
    function strategyConfig(address strategy) external view returns (StrategyConfig memory);
    function strategyState(address strategy) external view returns (StrategyState memory);

    function deploy(uint256 assets) external returns (uint256 deployed);
    function pullToVault(uint256 assets) external returns (uint256 received, uint256 loss);
    function harvest(address[] calldata strategies) external returns (HarvestSummary memory summary);
    function rebalance(RebalanceInstruction[] calldata instructions)
        external
        returns (uint256 deployed, uint256 withdrawn, uint256 loss);
}
