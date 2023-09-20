// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Hanjie Deng
 * Collateral: Exogenous
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This is the stablecoin that is meant to be governed by DSCEngine.
 * This contract is just the ERC20 implementation of our stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeGreaterThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__CanNotMintToZeroAddress();
    error DecentralizedStableCoin__MintAmountMustBeGreaterThanZero();

    //     /*
    //     In future versions of OpenZeppelin contracts package, Ownable must be declared with an address of the contract owner as a parameter.
    //     For example:
    //     constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) {}
    //     Related code changes can be viewed in this commit:
    //     https://github.com/OpenZeppelin/openzeppelin-contracts/commit/13d5e0466a9855e9305119ed383e54fc913fdc60
    //     */
    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeGreaterThanZero();
        }
        if (_amount > balance) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CanNotMintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MintAmountMustBeGreaterThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
