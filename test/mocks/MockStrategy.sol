// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { ISeraphStrategy } from "../../src/interfaces/ISeraphStrategy.sol";
import { SafeTransferLib } from "../../src/libraries/SafeTransferLib.sol";
import { StrategyReport, StrategyStatus } from "../../src/types/SeraphTypes.sol";

contract MockStrategy is ISeraphStrategy {
    using SafeTransferLib for IERC20;
    error OnlyVault();
    error InvalidReceiver();

    address public immutable override asset;
    address public immutable override vault;
    string public override name;

    StrategyStatus public override status = StrategyStatus.Active;
    uint256 public accountedAssets;
    uint256 public depositCapacity = type(uint256).max;
    uint256 public liquidAssets = type(uint256).max;

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address asset_, address vault_, string memory name_) {
        asset = asset_;
        vault = vault_;
        name = name_;
    }

    function totalAssets() external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function maxDeposit() external view override returns (uint256) {
        if (status != StrategyStatus.Active) return 0;
        return depositCapacity;
    }

    function maxWithdraw() external view override returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return liquidAssets < balance ? liquidAssets : balance;
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256 deployed) {
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assets);
        deployed = token.balanceOf(address(this)) - balanceBefore;
        accountedAssets += deployed;
        emit StrategyDeposit(deployed, token.balanceOf(address(this)));
    }

    function withdraw(uint256 assets, address receiver)
        external
        override
        onlyVault
        returns (uint256 withdrawn, uint256 loss)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        withdrawn = assets < balance ? assets : balance;
        if (withdrawn > liquidAssets) withdrawn = liquidAssets;
        if (withdrawn != 0) IERC20(asset).safeTransfer(receiver, withdrawn);
        uint256 reduction = withdrawn < accountedAssets ? withdrawn : accountedAssets;
        accountedAssets -= reduction;
        emit StrategyWithdrawal(receiver, assets, withdrawn, 0);
        return (withdrawn, 0);
    }

    function harvest() external override onlyVault returns (StrategyReport memory report) {
        IERC20 token = IERC20(asset);
        uint256 currentAssets = token.balanceOf(address(this));
        uint256 gain;
        uint256 loss;
        uint256 debtPayment;

        if (currentAssets >= accountedAssets) {
            gain = currentAssets - accountedAssets;
            debtPayment = gain;
            if (debtPayment != 0) token.safeTransfer(vault, debtPayment);
        } else {
            loss = accountedAssets - currentAssets;
        }

        uint256 endingAssets = token.balanceOf(address(this));
        accountedAssets = endingAssets;
        report = StrategyReport({
            totalAssets: endingAssets,
            gain: gain,
            loss: loss,
            debtPayment: debtPayment,
            timestamp: uint40(block.timestamp)
        });
        emit StrategyReported(endingAssets, gain, loss, debtPayment);
    }

    function shutdown() external override onlyVault {
        status = StrategyStatus.Retiring;
        emit StrategyShutdown();
    }

    function emergencyWithdraw(address receiver)
        external
        override
        onlyVault
        returns (uint256 withdrawn)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        status = StrategyStatus.Retiring;
        withdrawn = IERC20(asset).balanceOf(address(this));
        accountedAssets = 0;
        if (withdrawn != 0) IERC20(asset).safeTransfer(receiver, withdrawn);
        emit StrategyShutdown();
    }

    function setDepositCapacity(uint256 capacity) external {
        depositCapacity = capacity;
    }

    function setLiquidAssets(uint256 available) external {
        liquidAssets = available;
    }
}
