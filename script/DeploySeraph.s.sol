// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { FeeController } from "../src/core/FeeController.sol";
import { RewardDistributor } from "../src/core/RewardDistributor.sol";
import { RiskController } from "../src/core/RiskController.sol";
import { SeraphVault } from "../src/core/SeraphVault.sol";
import { StrategyRouter } from "../src/core/StrategyRouter.sol";
import { WithdrawalQueue } from "../src/core/WithdrawalQueue.sol";
import { IERC20Metadata } from "../src/interfaces/IERC20.sol";
import { SeraphShare } from "../src/token/SeraphShare.sol";
import { FeeConfig } from "../src/types/SeraphTypes.sol";

contract DeploySeraph is Script {
    event SeraphDeployment(
        address indexed vault,
        address indexed asset,
        address share,
        address rewards,
        address queue,
        address router,
        address risk,
        address fees,
        address governor,
        address guardian
    );

    SeraphVault public vault;
    SeraphShare public share;
    RewardDistributor public rewards;
    WithdrawalQueue public queue;
    StrategyRouter public router;
    RiskController public risk;
    FeeController public fees;

    function run() external returns (address vaultAddress) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address asset = vm.envAddress("SERAPH_ASSET");
        address finalGovernor = vm.envOr("SERAPH_GOVERNOR", deployer);
        address guardian = vm.envOr("SERAPH_GUARDIAN", address(0));
        address feeRecipient = vm.envOr("SERAPH_FEE_RECIPIENT", finalGovernor);
        uint256 unit = 10 ** IERC20Metadata(asset).decimals();

        vm.startBroadcast(deployerKey);

        vault = new SeraphVault(
            asset, deployer, guardian, vm.envOr("SERAPH_REWARD_ALLOCATION_BPS", uint256(5000))
        );
        share = new SeraphShare(
            vm.envOr("SERAPH_SHARE_NAME", string("Seraph Yield Share")),
            vm.envOr("SERAPH_SHARE_SYMBOL", string("sySERAPH")),
            IERC20Metadata(asset).decimals(),
            address(vault),
            address(0)
        );
        rewards = new RewardDistributor(deployer, guardian, asset, address(share), address(vault));
        queue = new WithdrawalQueue(
            deployer,
            guardian,
            address(vault),
            vm.envOr("SERAPH_WITHDRAWAL_DELAY", uint256(2 days)),
            vm.envOr("SERAPH_CLAIM_WINDOW", uint256(7 days)),
            vm.envOr("SERAPH_ROUND_DURATION", uint256(1 hours)),
            vm.envOr("SERAPH_MIN_REQUEST_SHARES", unit),
            vm.envOr("SERAPH_MAX_REQUEST_SHARES", uint256(0))
        );
        router = new StrategyRouter(asset, address(vault), deployer, guardian);
        risk = new RiskController(
            deployer,
            guardian,
            vm.envOr("SERAPH_DEPOSIT_CAP", uint256(0)),
            vm.envOr("SERAPH_MAX_QUEUED_BPS", uint256(8000)),
            vm.envOr("SERAPH_MAX_USER_QUEUED_BPS", uint256(5000)),
            vm.envOr("SERAPH_MIN_ACTIVE_SHARES", unit),
            vm.envOr("SERAPH_MIN_IDLE_BPS", uint256(1000)),
            vm.envOr("SERAPH_MAX_REPORT_LOSS_BPS", uint256(1000))
        );
        fees = new FeeController(
            deployer,
            guardian,
            address(vault),
            FeeConfig({
                performanceFeeBps: uint16(vm.envOr("SERAPH_PERFORMANCE_FEE_BPS", uint256(1000))),
                managementFeeBps: uint16(vm.envOr("SERAPH_MANAGEMENT_FEE_BPS", uint256(100))),
                withdrawalFeeBps: uint16(vm.envOr("SERAPH_WITHDRAWAL_FEE_BPS", uint256(25))),
                recipient: feeRecipient
            })
        );

        vault.initialize(
            address(share),
            address(rewards),
            address(queue),
            address(router),
            address(risk),
            address(fees)
        );
        router.setKeeper(address(vault), true);

        if (finalGovernor != deployer) _nominateGovernor(finalGovernor);

        emit SeraphDeployment(
            address(vault),
            asset,
            address(share),
            address(rewards),
            address(queue),
            address(router),
            address(risk),
            address(fees),
            finalGovernor,
            guardian
        );

        vm.stopBroadcast();
        return address(vault);
    }

    function _nominateGovernor(address finalGovernor) internal {
        vault.proposeGovernor(finalGovernor);
        rewards.proposeGovernor(finalGovernor);
        queue.proposeGovernor(finalGovernor);
        router.proposeGovernor(finalGovernor);
        risk.proposeGovernor(finalGovernor);
        fees.proposeGovernor(finalGovernor);
    }
}
