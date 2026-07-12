// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20Metadata } from "../../src/interfaces/IERC20.sol";

contract MockERC20 is IERC20Metadata {
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;

    uint256 public override totalSupply;
    mapping(address account => uint256 balance) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address receiver, uint256 amount) external {
        if (receiver == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[receiver] += amount;
        emit Transfer(address(0), receiver, amount);
    }

    function burn(address owner, uint256 amount) external {
        uint256 balance = balanceOf[owner];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[owner] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(owner, address(0), amount);
    }

    function transfer(address receiver, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, receiver, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 amount)
        external
        override
        returns (bool)
    {
        uint256 allowed = allowance[owner][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[owner][msg.sender] = allowed - amount;
            }
            emit Approval(owner, msg.sender, allowance[owner][msg.sender]);
        }
        _transfer(owner, receiver, amount);
        return true;
    }

    function _transfer(address owner, address receiver, uint256 amount) internal {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[owner];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[owner] = balance - amount;
            balanceOf[receiver] += amount;
        }
        emit Transfer(owner, receiver, amount);
    }
}
