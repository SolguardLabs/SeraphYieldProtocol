// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lightweight protocol role management with two-step governor handover.
abstract contract ProtocolAccess {
    error UnauthorizedGovernor(address caller);
    error UnauthorizedGuardian(address caller);
    error UnauthorizedKeeper(address caller);
    error UnauthorizedGovernorOrGuardian(address caller);
    error UnauthorizedGovernorOrKeeper(address caller);
    error AccessZeroAddress();
    error AlreadyGovernor(address account);
    error NotPendingGovernor(address caller, address expected);
    error AccessArrayLengthMismatch();

    event GovernorTransferStarted(address indexed governor, address indexed pendingGovernor);
    event GovernorTransferCancelled(address indexed governor, address indexed cancelledCandidate);
    event GovernorTransferred(address indexed previousGovernor, address indexed newGovernor);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event KeeperUpdated(address indexed keeper, bool authorized);

    address public governor;
    address public pendingGovernor;
    address public guardian;

    mapping(address keeper => bool authorized) public isKeeper;

    constructor(address initialGovernor, address initialGuardian) {
        if (initialGovernor == address(0)) revert AccessZeroAddress();

        governor = initialGovernor;
        guardian = initialGuardian;

        emit GovernorTransferred(address(0), initialGovernor);
        emit GuardianUpdated(address(0), initialGuardian);
    }

    modifier onlyGovernor() {
        _checkGovernor();
        _;
    }

    modifier onlyGuardian() {
        _checkGuardian();
        _;
    }

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    modifier onlyGovernorOrGuardian() {
        _checkGovernorOrGuardian();
        _;
    }

    modifier onlyGovernorOrKeeper() {
        _checkGovernorOrKeeper();
        _;
    }

    /// @notice Nominate the account that may accept the governor role.
    function proposeGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert AccessZeroAddress();
        if (newGovernor == governor) revert AlreadyGovernor(newGovernor);

        pendingGovernor = newGovernor;
        emit GovernorTransferStarted(governor, newGovernor);
    }

    /// @notice Cancel an outstanding governor nomination.
    function cancelGovernorTransfer() external onlyGovernor {
        address candidate = pendingGovernor;
        pendingGovernor = address(0);
        emit GovernorTransferCancelled(governor, candidate);
    }

    /// @notice Complete a governor handover. Callable only by the nominee.
    function acceptGovernor() external {
        address candidate = pendingGovernor;
        if (msg.sender != candidate || candidate == address(0)) {
            revert NotPendingGovernor(msg.sender, candidate);
        }

        address previousGovernor = governor;
        governor = candidate;
        pendingGovernor = address(0);

        emit GovernorTransferred(previousGovernor, candidate);
    }

    /// @notice Replace or disable the guardian. Setting address(0) disables it.
    function setGuardian(address newGuardian) external onlyGovernor {
        address previousGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(previousGuardian, newGuardian);
    }

    function setKeeper(address keeper, bool authorized) external onlyGovernor {
        if (keeper == address(0)) revert AccessZeroAddress();
        isKeeper[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    function setKeepers(address[] calldata keepers, bool[] calldata authorizations)
        external
        onlyGovernor
    {
        if (keepers.length != authorizations.length) revert AccessArrayLengthMismatch();

        for (uint256 i; i < keepers.length; ++i) {
            address keeper = keepers[i];
            if (keeper == address(0)) revert AccessZeroAddress();
            isKeeper[keeper] = authorizations[i];
            emit KeeperUpdated(keeper, authorizations[i]);
        }
    }

    function _checkGovernor() internal view {
        if (msg.sender != governor) revert UnauthorizedGovernor(msg.sender);
    }

    function _checkGuardian() internal view {
        if (msg.sender != guardian) revert UnauthorizedGuardian(msg.sender);
    }

    function _checkKeeper() internal view {
        if (!isKeeper[msg.sender]) revert UnauthorizedKeeper(msg.sender);
    }

    function _checkGovernorOrGuardian() internal view {
        if (msg.sender != governor && msg.sender != guardian) {
            revert UnauthorizedGovernorOrGuardian(msg.sender);
        }
    }

    function _checkGovernorOrKeeper() internal view {
        if (msg.sender != governor && !isKeeper[msg.sender]) {
            revert UnauthorizedGovernorOrKeeper(msg.sender);
        }
    }
}
