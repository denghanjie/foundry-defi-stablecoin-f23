// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Hanjie Deng
 * @notice This contract is the core of DSC system. It handles all the logic for minting and redeeming DSC,
 * as well as depositing and withdrawing collateral.
 *
 * Notice this contract is VERY loosely based on the MakerDao DSS (DAI) system.
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token = $1 pegged.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////////////
    // Errors              //
    /////////////////////////
    error DSCEngine__MoreThanZero();
    error DSCEngine__TokenAddressesAndPriceAddressesMustBeOfSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 _healthFactor);
    error DSCEngine__MintDSCFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    // Types              //
    /////////////////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    // State Variables     //
    /////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_DscMinted;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    /////////////////////////
    // Events              //
    /////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ////////////////////////////
    // Modifiers              //
    ////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////////////////
    // Functions              //
    ////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceAddressesMustBeOfSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    // External Functions     //
    ////////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice CEI: Checks, Effects, Interactions
     * @param collateralTokenAddress The address of the collateral token.
     * @param amountCollateral The amount of collateral token deposited.
     */
    function depositCollateral(address collateralTokenAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, amountCollateral);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction.
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // In order to redeem collateral;
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY: Don't Repeat Yourself
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // 100 - 1000 (revert)
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint.
     * @notice They must have more value than the minimum threshold.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        // if they minted too much, revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDscToMint);
        if (!success) {
            revert DSCEngine__MintDSCFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit
    }

    /**
     *
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

        uint256 amountTokenFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusTokenFromDebtCovered = amountTokenFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;

        uint256 totalAmountCollateralToRedeem = amountTokenFromDebtCovered + bonusTokenFromDebtCovered;

        _redeemCollateral(user, msg.sender, collateral, totalAmountCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////////
    // Private & Internal Functions     //
    //////////////////////////////////////

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        internal
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-leverl internal function, do not call unless the function calling it is
     * checking for health factors being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) internal {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is.
     * If a user goes below 1, then they can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total Collateral Value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        // if (totalDscMinted == 0) {
        //     return 1e18; // if not minted DSC token, no debt, sets health factor to 1
        // }

        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(userHealthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //////////////////////////////////////////
    // Public & External View Functions     //
    //////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        public
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 usdValue) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        usdValue = ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInUsd) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInUsd * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getPriceFeed(address collateral) public view returns (address priceFeed) {
        return s_priceFeeds[collateral];
    }

    function getCollateralTokens(uint256 id) public view returns (address) {
        return s_collateralTokens[id];
    }

    function getCollateralAmount(address user, address collateral) public view returns (uint256) {
        return s_collateralDeposited[user][collateral];
    }

    function getCollateralBalanceOfUser(address collateral, address user) public view returns (uint256) {
        return getCollateralAmount(user, collateral);
    }

    function getDscAddress() public view returns (address) {
        return address(i_dsc);
    }

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }
}
