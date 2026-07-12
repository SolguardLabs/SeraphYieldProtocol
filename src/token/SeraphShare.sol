// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20Metadata, IERC20Permit } from "../interfaces/IERC20.sol";
import { IShareTransferHook } from "../interfaces/IShareTransferHook.sol";

/// @notice Vault share token with EIP-2612 approvals and withdrawal locks.
/// @dev Locked shares remain owned by the account but cannot be transferred or actively burned.
contract SeraphShare is IERC20Metadata, IERC20Permit {
    error ZeroAddress();
    error UnauthorizedVault(address caller);
    error UnauthorizedLocker(address caller);
    error InsufficientBalance(address account, uint256 available, uint256 required);
    error InsufficientActiveBalance(address account, uint256 available, uint256 required);
    error InsufficientLockedBalance(address account, uint256 available, uint256 required);
    error InsufficientAllowance(
        address owner, address spender, uint256 available, uint256 required
    );
    error PermitExpired(uint256 deadline);
    error InvalidPermitSignature();
    error HookReentrancy();

    event QueueUpdated(address indexed previousQueue, address indexed newQueue);
    event TransferHookUpdated(address indexed previousHook, address indexed newHook);
    event SharesLocked(address indexed account, address indexed operator, uint256 amount);
    event SharesUnlocked(address indexed account, address indexed operator, uint256 amount);
    event LockedSharesBurned(address indexed account, address indexed operator, uint256 amount);

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _VERSION_HASH = keccak256("1");
    uint256 private constant _SECP256K1N_HALF =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    uint256 public override totalSupply;
    uint256 public totalLocked;

    address public immutable vault;
    IShareTransferHook public transferHook;
    address public queue;

    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;
    mapping(address owner => uint256 nonce) public override nonces;
    mapping(address account => uint256 shares) public lockedShares;

    uint256 private immutable _initialChainId;
    bytes32 private immutable _initialDomainSeparator;
    bool private _callingHook;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address vault_,
        address hook_
    ) {
        if (vault_ == address(0)) revert ZeroAddress();

        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        vault = vault_;
        transferHook = IShareTransferHook(hook_);

        _initialChainId = block.chainid;
        _initialDomainSeparator = _computeDomainSeparator();
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert UnauthorizedVault(msg.sender);
        _;
    }

    modifier onlyLocker() {
        if (msg.sender != vault && msg.sender != queue) revert UnauthorizedLocker(msg.sender);
        _;
    }

    /// @notice Shares owned by an account that remain economically active and transferable.
    function activeBalanceOf(address account) public view returns (uint256) {
        return balanceOf[account] - lockedShares[account];
    }

    function lockedBalanceOf(address account) external view returns (uint256) {
        return lockedShares[account];
    }

    /// @notice Supply participating in active vault accounting.
    function activeSupply() public view returns (uint256) {
        return totalSupply - totalLocked;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Mint active shares. Only the vault may alter supply.
    function mint(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert ZeroAddress();

        _beforeActiveShareChange(address(0), to, amount);

        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn active shares from an account.
    function burn(address from, uint256 amount) external onlyVault {
        if (from == address(0)) revert ZeroAddress();
        uint256 active = activeBalanceOf(from);
        if (active < amount) revert InsufficientActiveBalance(from, active, amount);

        _beforeActiveShareChange(from, address(0), amount);

        unchecked {
            balanceOf[from] -= amount;
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    /// @notice Exclude shares from the account's active balance while preserving ownership.
    /// @dev Lock bookkeeping does not alter the ERC-20 balance or total supply.
    function lock(address account, uint256 amount) external onlyLocker {
        if (account == address(0)) revert ZeroAddress();
        uint256 active = activeBalanceOf(account);
        if (active < amount) revert InsufficientActiveBalance(account, active, amount);

        lockedShares[account] += amount;
        totalLocked += amount;

        emit SharesLocked(account, msg.sender, amount);
    }

    /// @notice Return previously locked shares to the active balance.
    /// @dev Unlocking restores transfer capacity without changing ownership.
    function unlock(address account, uint256 amount) external onlyLocker {
        if (account == address(0)) revert ZeroAddress();
        uint256 locked = lockedShares[account];
        if (locked < amount) revert InsufficientLockedBalance(account, locked, amount);

        unchecked {
            lockedShares[account] = locked - amount;
            totalLocked -= amount;
        }

        emit SharesUnlocked(account, msg.sender, amount);
    }

    /// @notice Burn shares that have completed the withdrawal flow.
    /// @dev Total supply and locked supply fall equally, so active supply does not change.
    function burnLocked(address account, uint256 amount) external onlyLocker {
        if (account == address(0)) revert ZeroAddress();
        uint256 locked = lockedShares[account];
        if (locked < amount) revert InsufficientLockedBalance(account, locked, amount);

        unchecked {
            lockedShares[account] = locked - amount;
            totalLocked -= amount;
            balanceOf[account] -= amount;
            totalSupply -= amount;
        }

        emit LockedSharesBurned(account, msg.sender, amount);
        emit Transfer(account, address(0), amount);
    }

    /// @notice Authorize a withdrawal queue to lock, unlock, and burn locked shares.
    /// @dev Setting the zero address removes the current queue authorization.
    function setQueue(address newQueue) external onlyVault {
        address previousQueue = queue;
        queue = newQueue;
        emit QueueUpdated(previousQueue, newQueue);
    }

    /// @notice Replace the accounting callback used for active balance changes.
    function setTransferHook(address newHook) external onlyVault {
        address previousHook = address(transferHook);
        transferHook = IShareTransferHook(newHook);
        emit TransferHookUpdated(previousHook, newHook);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        // A timestamp is required by EIP-2612 to enforce the signed permit deadline.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert PermitExpired(deadline);
        if (owner == address(0)) revert InvalidPermitSignature();
        if (uint256(s) > _SECP256K1N_HALF || (v != 27 && v != 28)) {
            revert InvalidPermitSignature();
        }

        uint256 nonce = nonces[owner];
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != owner) revert InvalidPermitSignature();

        unchecked {
            nonces[owner] = nonce + 1;
        }
        _approve(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return
            block.chainid == _initialChainId ? _initialDomainSeparator : _computeDomainSeparator();
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();

        uint256 active = activeBalanceOf(from);
        if (active < amount) revert InsufficientActiveBalance(from, active, amount);

        _beforeActiveShareChange(from, to, amount);

        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) {
            revert InsufficientAllowance(owner, spender, current, amount);
        }

        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, allowance[owner][spender]);
    }

    function _beforeActiveShareChange(address from, address to, uint256 amount) internal {
        if (address(transferHook) == address(0)) return;
        if (_callingHook) revert HookReentrancy();

        _callingHook = true;
        transferHook.beforeShareTransfer(from, to, amount);
        _callingHook = false;
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(name)),
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }
}
