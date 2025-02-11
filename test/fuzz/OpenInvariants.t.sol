// // SPDX-License-Identifier: MIT

// pragma solidity ^0.8.18;
// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     HelperConfig config;
//     DecentralizedStableCoin dsc;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (, , weth, wbtc, ) = config.activeNetworkConfig();

//         // Set the target contract for invariant checks
//         targetContract(address(dsce));
//     }

//     // Mark the function as a test with the test keyword
//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
//         uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

//         uint256 totalValue = wethValue + wbtcValue;
//         assert(totalValue >= totalSupply);

//         // Log details for debugging
//         console.log("Total Supply:", totalSupply);
//         console.log("Total WETH Deposited:", totalWethDeposited);
//         console.log("Total BTC Deposited:", totalBtcDeposited);
//     }
// }
