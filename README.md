1. Relative stability Anchored and Pegged -> $1.00
   1. chainlink price feed
   2. Set the function to exchange ETH & BTC -> $$$$
2. Stability Mechanism (Minting) : Algorithemic(Decentralized)
   1. People can only mint stable coin with enough collateral (coded)
3. collateral : Exogenous (Crypto)
   1. wETH
   2. wBTC

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
/////////////////////////
// Errors //
////////////////////////
error DSCEngine**NeedMoreThanZero();
error DSCEngine**TokenAddressesAndPriceFeedAddressesMustBeSameLength();
error DSCEngine**NotAllowedToken();
error DSCEngine**Transfailed();
error DSCEngine**BreaksHealthFactor(uint256 healthFactor);
error DSCEngine**MintFailed();
error DSCEngine**TransferFailed();
error DSCEngine**HealthFactorOk();
error DSCEngine\_\_HealthFactorNotImproved();
/////////////////////////
// State Variables //
/////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount))
        public s_collateralDeposit;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////////
    // Events //
    ////////////////////////
    event CollateralDeposit(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    /////////////////////////
    // Modifiers //
    ////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////////////
    // Functions //
    ////////////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions //
    ////////////////////////


    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDSCToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The Address of the token to deposit  as Collateral.
     * @param amountCollateral The ammount of Collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposit[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposit(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__Transfailed();
        }
        _revertIfHelthFactorIsBroken(msg.sender);
    }



    // CEI: check , facts , intractions
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHelthFactorIsBroken(msg.sender);
    }


    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }


    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHelthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHelthFactorIsBroken(msg.sender);
    }

    /
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // If covering 100 DSC, we need to have $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHelthFactorIsBroken(msg.sender);
    }

    function getHealhFactor() external view {}

    /////////////////////////
    // Private And Internal View Functions //
    ////////////////////////

    /*
     * @dev Low-level internal function , do not call unless the function it is.
     * checking the health factor is broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__Transfailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposit[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns How close the liquidation user is.
     * if a user goes below 1  , then they can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHelthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////
    // Public and External view Functions //
    ////////////////////////

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposit[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import "forge-std/console.sol";

contract DSCEngineTest is Test {
DeployDSC deployer;
DecentralizedStableCoin dsc;
DSCEngine dsce;
HelperConfig config;
address ethUsdPriceFeed;
address btcUsdPriceFeed;
address weth;
address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config
            .activeNetworkConfig();

        // Mint tokens to USER
        // ERC20Mock(weth).mint(address(this), STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        console.log(
            "==================================USER Balance",
            ERC20Mock(weth).balanceOf(USER)
        );
    }

    // //////////////
    // Constructor Test //
    // //////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // //////////////
    // Price Test //
    // //////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;

        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    // //////////////
    // Deposit Collateral Test //
    // //////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        console.log("===================================", USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnApprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock(
            "RAN",
            "RAN",
            USER,
            AMOUNT_COLLATERAL
        );
        {}

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), 10 ether); this line has an issue.
        vm.stopPrank();
    }

    // function testCheckBalance() public {
    //     vm.startPrank(USER);
    //     uint256 balance = ERC20Mock(weth).balanceOf(USER);
    //     bool success = ERC20Mock(weth).approve(
    //         address(dsce),
    //         AMOUNT_COLLATERAL
    //     );
    //     vm.stopPrank();
    //     // assertEq(success, true);
    //     console.log("User Balance =========================", balance);
    //     // assertEq(balance, AMOUNT_COLLATERAL);
    // }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositedCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        // (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
        //     .getAccountInformation(USER);
        // uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(
        //     weth,
        //     collateralValueInUsd
        // );
        // // assertEq(totalDscMinted, 0);
        // assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

}

forge test --match-test testCanDepositedCollateralAndGetAccountInfo -vvvv
[⠢] Compiling...
[⠊] Compiling 1 files with Solc 0.8.24
[⠒] Solc 0.8.24 finished in 2.78s
Compiler run successful with warnings:
Warning (2072): Unused local variable.
--> script/DeployDSC.s.sol:19:90:
|
19 | (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
| ^^^^^^^^^^^^^^^^^^^

Warning (2018): Function state mutability can be restricted to view
--> test/unit/DSCEngineTest.t.sol:72:5:
|
72 | function testGetTokenAmountFromUsd() public {
| ^ (Relevant source part starts here and spans across multiple lines).

Ran 1 test for test/unit/DSCEngineTest.t.sol:DSCEngineTest
[FAIL: panic: division or modulo by zero (0x12)] testCanDepositedCollateralAndGetAccountInfo() (gas: 144643)
Logs:
==================================USER Balance 10000000000000000000

Traces:
[10432746] DSCEngineTest::setUp()
├─ [4672358] → new DeployDSC@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
│ └─ ← [Return] 23224 bytes of code
├─ [5526973] DeployDSC::run()
│ ├─ [3692685] → new HelperConfig@0x104fBc016F4bb334D775a19E8A6510109AC63E00
│ │ ├─ [0] VM::startBroadcast()
│ │ │ └─ ← [Return]
│ │ ├─ [367042] → new <unknown>@0x34A1D3fff3958843C43aD80F30b94c510645C316
│ │ │ └─ ← [Return] 1056 bytes of code
│ │ ├─ [367042] → new <unknown>@0x90193C961A926261B756D1E5bb255e67ff9498A1
│ │ │ └─ ← [Return] 1056 bytes of code
│ │ ├─ [650674] → new <unknown>@0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496
│ │ │ ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: DeployDSC: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], value: 1000000000000000000000 [1e21])
│ │ │ └─ ← [Return] 2788 bytes of code
│ │ ├─ [650674] → new <unknown>@0xBb2180ebd78ce97360503434eD37fcf4a1Df61c3
│ │ │ ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: DeployDSC: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], value: 1000000000000000000000 [1e21])
│ │ │ └─ ← [Return] 2788 bytes of code
│ │ ├─ [0] VM::stopBroadcast()
│ │ │ └─ ← [Return]
│ │ └─ ← [Return] 6832 bytes of code
│ ├─ [911] HelperConfig::activeNetworkConfig() [staticcall]
│ │ └─ ← [Return] 0x34A1D3fff3958843C43aD80F30b94c510645C316, 0x90193C961A926261B756D1E5bb255e67ff9498A1, 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, 0xBb2180ebd78ce97360503434eD37fcf4a1Df61c3, 77814517325470205911140941194401928579557062014761831930645393041380819009408 [7.781e76]
│ ├─ [0] VM::startBroadcast()
│ │ └─ ← [Return]
│ ├─ [740201] → new <unknown>@0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76
│ │ ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
│ │ └─ ← [Return] 3353 bytes of code
│ ├─ [852032] → new DSCEngine@0x50EEf481cae4250d252Ae577A09bF514f224C6C4
│ │ └─ ← [Return] 3578 bytes of code
│ ├─ [2443] 0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76::transferOwnership(DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4])
│ │ ├─ emit OwnershipTransferred(previousOwner: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38], newOwner: DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4])
│ │ └─ ← [Stop]
│ ├─ [0] VM::stopBroadcast()
│ │ └─ ← [Return]
│ └─ ← [Return] 0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76, DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], HelperConfig: [0x104fBc016F4bb334D775a19E8A6510109AC63E00]
├─ [911] HelperConfig::activeNetworkConfig() [staticcall]
│ └─ ← [Return] 0x34A1D3fff3958843C43aD80F30b94c510645C316, 0x90193C961A926261B756D1E5bb255e67ff9498A1, 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, 0xBb2180ebd78ce97360503434eD37fcf4a1Df61c3, 77814517325470205911140941194401928579557062014761831930645393041380819009408 [7.781e76]
├─ [24724] 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496::mint(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], 10000000000000000000 [1e19])
│ ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], value: 10000000000000000000 [1e19])
│ └─ ← [Stop]
├─ [604] 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496::balanceOf(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D]) [staticcall]
│ └─ ← [Return] 10000000000000000000 [1e19]
├─ [0] console::log("==================================USER Balance", 10000000000000000000 [1e19]) [staticcall]
│ └─ ← [Stop]
└─ ← [Stop]

[144643] DSCEngineTest::testCanDepositedCollateralAndGetAccountInfo()
├─ [0] VM::startPrank(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D])
│ └─ ← [Return]
├─ [24647] 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496::approve(DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], 10000000000000000000 [1e19])
│ ├─ emit Approval(owner: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], spender: DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], value: 10000000000000000000 [1e19])
│ └─ ← [Return] true
├─ [104529] DSCEngine::depositCollateral(0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, 10000000000000000000 [1e19])
│ ├─ emit CollateralDeposit(user: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], token: 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496, amount: 10000000000000000000 [1e19])
│ ├─ [32479] 0xA8452Ec99ce0C64f20701dB7dD3abDb607c00496::transferFrom(user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], 10000000000000000000 [1e19])
│ │ ├─ emit Approval(owner: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], spender: DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], value: 0)
│ │ ├─ emit Transfer(from: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], to: DSCEngine: [0x50EEf481cae4250d252Ae577A09bF514f224C6C4], value: 10000000000000000000 [1e19])
│ │ └─ ← [Return] true
│ ├─ [8991] 0x34A1D3fff3958843C43aD80F30b94c510645C316::latestRoundData() [staticcall]
│ │ └─ ← [Return] 1, 200000000000 [2e11], 1, 1, 1
│ ├─ [8991] 0x90193C961A926261B756D1E5bb255e67ff9498A1::latestRoundData() [staticcall]
│ │ └─ ← [Return] 1, 100000000000 [1e11], 1, 1, 1
│ └─ ← [Revert] panic: division or modulo by zero (0x12)
└─ ← [Revert] panic: division or modulo by zero (0x12)

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 2.96ms (318.82µs CPU time)

Ran 1 test suite in 1.48s (2.96ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/unit/DSCEngineTest.t.sol:DSCEngineTest
[FAIL: panic: division or modulo by zero (0x12)] testCanDepositedCollateralAndGetAccountInfo() (gas: 144643)

Encountered a total of 1 failing tests, 0 tests succeeded

import {AggregatorV3Interface} from
"../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
