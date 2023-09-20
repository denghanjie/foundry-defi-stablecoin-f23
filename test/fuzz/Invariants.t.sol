// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreCollateralValueThanDscTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 totalWethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 totalWbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("Total Weth value: ", totalWethValue);
        console.log("Total Wbtc value: ", totalWbtcValue);
        console.log("Total Supply: ", totalSupply);
        console.log("Times MintDsc called: ", handler.timesMintDscCalled());

        assert(totalWethValue + totalWbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNeverRevert() public view {}
}
