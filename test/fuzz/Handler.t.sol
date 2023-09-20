// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    address weth;
    address wbtc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public timesMintDscCalled;
    address[] public usersWithCollateralDeposited;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        weth = dsce.getCollateralTokens(0);
        wbtc = dsce.getCollateralTokens(1);
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddress = _getCollateralAddressBySeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        ERC20Mock(collateralAddress).mint(msg.sender, collateralAmount);
        ERC20Mock(collateralAddress).approve(address(dsce), collateralAmount);
        dsce.depositCollateral(collateralAddress, collateralAmount);
        vm.stopPrank();
        // double push involved here
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address user = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(user);
        int256 maxDscMinted = (int256(totalCollateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscMinted < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscMinted));
        if (amount == 0) {
            return;
        }
        vm.startPrank(user);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintDscCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddress = _getCollateralAddressBySeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(collateralAddress, msg.sender);
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);
        if (collateralAmount == 0) {
            return;
        }
        dsce.redeemCollateral(collateralAddress, collateralAmount);
    }

    function _getCollateralAddressBySeed(uint256 collateralSeed) private view returns (address) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
