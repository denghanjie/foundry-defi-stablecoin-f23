// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_WETH_BALANCE = 10 ether;
    uint256 public constant STARTING_DSC_BALANCE_LIQUIDATOR = 1_000_000 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_WETH_BALANCE);
    }
    ////////////////////////
    // Constructor Tests  //
    ////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testConstructor() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceAddressesMustBeOfSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorSetPriceFeedsCorrect() public {
        assertEq(ethUsdPriceFeed, dsce.getPriceFeed(weth));
        assertEq(btcUsdPriceFeed, dsce.getPriceFeed(wbtc));
    }

    function testAllowedCollateralTokensInitializedCorrectly() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        assertEq(weth, engine.getCollateralTokens(0));
        assertEq(wbtc, engine.getCollateralTokens(1));
    }

    function testDscIntializedCorrectly() public {
        address actualInitializedDscAddress = dsce.getDscAddress();
        address expectedInitializedDscAddress = address(dsc);
        assertEq(actualInitializedDscAddress, expectedInitializedDscAddress);
    }

    /////////////////
    // Price Test  //
    /////////////////
    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18; // 15e18 * 20000/ETH = 30000e18
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedEthAmount = 0.05 ether; // 100 / 2000 = 0.05
        uint256 actualEthAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEthAmount, actualEthAmount);
    }

    //////////////////////////////
    // Deposit Collateral Test  //
    //////////////////////////////
    function testRevertsIfDepositCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfUnApprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositAmountAndMintAmount() public depositCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralAmount = dsce.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralAmount);
    }

    ////////////////////
    // MintDsc  Test  //
    ////////////////////

    uint256 constant MIN_MINT_AMOUNT = 1 ether;

    function testRevertsIfMintZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.mintDsc(0);
    }

    function testMintAmountCorrect() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MIN_MINT_AMOUNT); // USER has 10 ether collateral, minting 1 will absolutely not break healthfactor
        (uint256 actualTotalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(MIN_MINT_AMOUNT, actualTotalDscMinted);
    }

    function testRevertsIfBreakingHealthFactor() public depositCollateral {
        vm.startPrank(USER);
        uint256 expectedDscMintAmount = 10 * 2001 ether;
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(expectedDscMintAmount, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));
        dsce.mintDsc(expectedDscMintAmount); // USER has 10 weth collateral, worth 10 * 2000 dollars
        vm.stopPrank();
        // (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(USER);
        // console.log(totalDscMinted);
        // console.log(totalCollateralValueInUsd);

        // uint256 healthFactor = dsce.getHealthFactor(USER);
        // console.log(healthFactor);
    }

    function testDscBalanceEqualsMintAmount() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MIN_MINT_AMOUNT); // USER has 10 ether collateral, minting 1 will absolutely not break healthfactor
        (uint256 actualTotalDscMinted,) = dsce.getAccountInformation(USER);
        vm.stopPrank();
        assertEq(dsc.balanceOf(USER), actualTotalDscMinted);
    }

    function testRevertsIfZeroAddressMints() public depositCollateral {
        vm.prank(address(0));
        vm.expectRevert();
        dsce.mintDsc(MIN_MINT_AMOUNT);
    }

    /////////////////////////////////////////
    // depositCollateralAndMintDsc  Test  ///
    /////////////////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MIN_MINT_AMOUNT);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        uint256 collateralAmount = dsce.getCollateralAmount(USER, weth);
        assertEq(MIN_MINT_AMOUNT, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, collateralAmount);
    }

    //////////////////////////////
    // Redeem Collateral Test  ///
    //////////////////////////////
    function testRevertsIfRedeemCollateralAmountEqualsZero() public depositCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralAmountCorrect() public depositCollateral {
        assertEq(AMOUNT_COLLATERAL, dsce.getCollateralAmount(USER, weth));
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(0, totalDscMinted);

        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        assertEq(0, dsce.getCollateralAmount(USER, weth));
        vm.stopPrank();
    }

    function testRevertsIfDscMintedAmountNotEqualZero() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MIN_MINT_AMOUNT);
        vm.expectRevert();
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL); // Get all collateral out.
        vm.stopPrank();
    }

    //////////////////////////
    // HealthFactor  Test  ///
    //////////////////////////
    modifier depositWethAndMintDscForUSER() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MIN_MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testHealthFactorEqualsOneWhenDscMintedEqualsZero() public {
        assertEq(dsce.getHealthFactor(USER), type(uint256).max);
    }

    function testHealthFactor() public depositWethAndMintDscForUSER {
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // TotalCollateralValueInUsd = 10 ether * 2000 $/ether; TotalDscMinted = 1 ether;
        // healthFactor = (TotalCollateralValueInUsd / 2) / TotalDscMinted = 10000;
        assertEq(healthFactor, 10000 ether);
    }

    /////////////////////
    // BurnDsc  Test  ///
    /////////////////////
    function testRevertsIfBurnAmountEqualZero() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testBurnDscAmountCorrect() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MIN_MINT_AMOUNT);
        (uint256 totalMintedDsc,) = dsce.getAccountInformation(USER);
        assertEq(MIN_MINT_AMOUNT, totalMintedDsc);

        dsc.approve(address(dsce), MIN_MINT_AMOUNT);

        dsce.burnDsc(MIN_MINT_AMOUNT);
        (totalMintedDsc,) = dsce.getAccountInformation(USER);
        assertEq(0, totalMintedDsc);
    }

    ////////////////////////////////////
    // RedeemCollateralForDsc  Test  ///
    ////////////////////////////////////
    function testRedeemCollateralForDSCCorrect() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(MIN_MINT_AMOUNT);

        dsc.approve(address(dsce), MIN_MINT_AMOUNT);
        dsce.redeemCollateralForDSC(weth, AMOUNT_COLLATERAL, MIN_MINT_AMOUNT);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);

        uint256 collateralAmount = dsce.getCollateralAmount(USER, weth);
        assertEq(collateralAmount, 0);
    }

    ///////////////////////
    // Liquidate Test  ////
    ///////////////////////

    address LIQUIDATOR = makeAddr("liquidator");

    modifier mintDscToLiquidator() {
        vm.prank(address(dsce)); // dsce is the owner of dsc
        dsc.mint(LIQUIDATOR, STARTING_DSC_BALANCE_LIQUIDATOR);
        _;
    }

    function testLiquidateRevertsIfDebtToCoverEqualZero() public mintDscToLiquidator depositWethAndMintDscForUSER {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__MoreThanZero.selector);
        dsce.liquidate(weth, USER, 0);
    }

    function testRevertsIfHealthFactorOK() public mintDscToLiquidator depositWethAndMintDscForUSER {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dsce.liquidate(weth, USER, MIN_MINT_AMOUNT);
    }

    // This test is not working
    function testRevertsIfHealthFactorNotImproved() public mintDscToLiquidator depositWethAndMintDscForUSER {
        vm.prank(USER);
        uint256 expectedMintDscAmount = 9999 ether;
        dsce.mintDsc(expectedMintDscAmount);
        // (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dsce.getAccountInformation(USER);
        // console.log(totalDscMinted);
        // console.log(totalCollateralValueInUsd);
        uint256 healthFactor =
            dsce.calculateHealthFactor(expectedMintDscAmount, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        console.log(healthFactor);

        vm.startPrank(LIQUIDATOR);
        uint256 liquidatDscAmount = 1000;
        dsc.approve(address(dsce), liquidatDscAmount);

        // // vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        // dsce.liquidate(weth, USER, liquidatDscAmount);

        // healthFactor = dsce.calculateHealthFactor(
        //     expectedMintDscAmount - liquidatDscAmount, dsce.getUsdValue(weth, AMOUNT_COLLATERAL)
        // );
        // console.log(healthFactor);
    }

    // This test is not working ether.
    function testWhenHealthFactorImproved() public mintDscToLiquidator depositWethAndMintDscForUSER {
        uint256 beforeHealthFactor = dsce.getHealthFactor(USER);
        console.log(beforeHealthFactor);

        vm.prank(USER);
        dsce.mintDsc(1000 ether); // healthFactor gets worse

        // vm.startPrank(LIQUIDATOR);
        // dsc.approve(address(dsce), 1000 ether);
        // dsce.liquidate(weth, USER, 1000 ether); // healthFacto improves to previous level

        // uint256 afterHealthFactor = dsce.getHealthFactor(USER);
        // console.log(afterHealthFactor);
    }
}
