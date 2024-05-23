// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/uniswap-interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import "../interfaces/IAsset.sol";

contract Asset is IAsset {
    bool initialized = false;

    ISwapRouter public swapRouter;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public assetTokenAddress;
    // For this example, we will set the pool fee to 0.3%.
    uint24 public constant poolFee = 3000;
    // address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    //vars
    address public uniV3PoolAddress;
    int56[7] public priceHistory;

    int256 public mostRecentSharpe;
    uint256 public mostRecentSTD;
    int256 public mostRecentReturn;
    uint256 public mostRecentPriceUpdateTime;

    //constructor
    constructor() {}

    function initialize (address _uniV3PoolAddress, int56[7] memory _priceHistory, address _swapRouter) public {
        swapRouter = ISwapRouter(_swapRouter);

        uniV3PoolAddress = _uniV3PoolAddress;
        assetTokenAddress = IUniswapV3Pool(uniV3PoolAddress).token0();

        priceHistory = _priceHistory;
        mostRecentPriceUpdateTime = block.timestamp;
        updateSharpe();

        initialized = true;

        require(IUniswapV3Pool(uniV3PoolAddress).token1() == USDC, "Pool must have USDC as token1");
    }

    // Functions
    function writeMostRecentPrice() public {
        // Ensure the function can only be called once per day
        require(block.timestamp - mostRecentPriceUpdateTime > 86400, "Price can only be updated once a day");

        // Instantiate the Uniswap pool interface
        IUniswapV3Pool uniV3Pool = IUniswapV3Pool(uniV3PoolAddress);

        // Prepare the time points for observation (1 hour ago and now)
        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = 3600; // 1 hour ago
        secondAgos[1] = 0;    // Now

        // Observe price data from Uniswap pool
        (int56[] memory tickCumulatives, ) = uniV3Pool.observe(secondAgos);

        // Ensure the observation data is valid
        require(tickCumulatives.length == 2, "Invalid observation data");

        // Calculate the average tick over the period
        int56 tickDifference = tickCumulatives[1] - tickCumulatives[0];
        int56 averageTick = tickDifference / 3600; // Average tick per second over the hour

        // Shift the price history array to the left
        for (uint256 i = 0; i < priceHistory.length - 1; i++) {
            priceHistory[i] = priceHistory[i + 1];
        }

        // Update the price history with the most recent price
        priceHistory[priceHistory.length - 1] = averageTick;

        // Update the most recent price update time
        mostRecentPriceUpdateTime = block.timestamp;

        // Update the Sharpe ratio
        updateSharpe();
    }

    function updateSharpe() public {
        // require(initialized, "Contract not initialized");

        // Calculate the daily returns
        int256[] memory daily_returns = new int256[](6);
        for (uint i = 0; i < 6; i++) {
            daily_returns[i] = int256(priceHistory[i + 1] - priceHistory[i]) * 1e18 / int256(priceHistory[i]);
        }

        // Assume a daily risk-free rate (let's take an example of 0.01% daily risk-free rate)
        int256 dailyRiskFreeRate = 1e12; // 0.01% in 1e18 format

        // Calculate the excess returns
        int256[] memory excessReturns = new int256[](6);
        for (uint i = 0; i < 6; i++) {
            excessReturns[i] = daily_returns[i] - dailyRiskFreeRate;
        }

        // Calculate the mean of the excess returns
        int256 sum = 0;
        for (uint i = 0; i < 6; i++) {
            sum += excessReturns[i];
        }
        int256 meanExcessReturn = sum / 6;

        // Calculate the standard deviation of the excess returns
        uint256 sumSquaredDifferences = 0;
        for (uint i = 0; i < 6; i++) {
            int256 diff = excessReturns[i] - meanExcessReturn;
            sumSquaredDifferences += uint256(diff * diff);
        }
        uint256 variance = sumSquaredDifferences / 6;
        uint256 standardDeviation = sqrt(variance);

        // Calculate the Sharpe ratio
        int256 sharpe;
        if (standardDeviation != 0) {
            sharpe = (meanExcessReturn * 1e18) / int256(standardDeviation); // Scale to maintain precision
        } else {
            sharpe = 0; // Avoid division by zero
        }

        // Update the most recent Sharpe ratio
        mostRecentSharpe = sharpe;
        mostRecentSTD = standardDeviation;
        mostRecentReturn = meanExcessReturn;
    }

    // Babylonian method for square root
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }


    /// @notice swapExactInputSingle swaps a fixed amount of TOKEN_IN for a maximum possible amount of TOKEN_OUT
    /// using the USDC/Asset 0.3% pool by calling `exactInputSingle` in the swap router.
    /// @dev The calling address must approve this contract to spend at least `amountIn` worth of its USDC for this function to succeed.
    /// @param amountIn The exact amount of USDC that will be swapped for Asset.
    /// @return amountOut The amount of Asset received.
    function swap(uint256 amountIn, bool usingUSDC) external returns (uint256 amountOut) {

        address TOKEN_IN;
        address TOKEN_OUT;

        if (usingUSDC) {
            TOKEN_IN = USDC;
            TOKEN_OUT = assetTokenAddress;
        } else {
            TOKEN_IN = assetTokenAddress;
            TOKEN_OUT = USDC;
        }

        // msg.sender must approve this contract

        // Transfer the specified amount of TOKEN_IN to this contract.
        TransferHelper.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);

        // Approve the router to spend TOKEN_IN.
        TransferHelper.safeApprove(TOKEN_IN, address(swapRouter), amountIn);

        // Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
        // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: TOKEN_IN,
                tokenOut: TOKEN_OUT,
                fee: poolFee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        // The call to `exactInputSingle` executes the swap.
        amountOut = swapRouter.exactInputSingle(params);
    }

    // Getters
    function getUniPoolInfo() public view returns (int56, address, address, address, uint24, int24, uint128) {
        IUniswapV3Pool uniV3Pool = IUniswapV3Pool(uniV3PoolAddress);


        // Prepare the time points for observation (1 hour ago and now)
        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = 3600; // 1 hour ago
        secondAgos[1] = 0;    // Now

        // Observe price data from Uniswap pool
        (int56[] memory tickCumulatives, ) = uniV3Pool.observe(secondAgos);

        // Ensure the observation data is valid
        require(tickCumulatives.length == 2, "Invalid observation data");

        // Calculate the average tick over the period
        int56 tickDifference = (tickCumulatives[1]) - (tickCumulatives[0]);
        int56 averageTick = (tickDifference) / 3600; // Average tick per second over the hour

        return (averageTick, uniV3Pool.factory(), uniV3Pool.token0(), uniV3Pool.token1(), uniV3Pool.fee(), uniV3Pool.tickSpacing(), uniV3Pool.maxLiquidityPerTick());
    }

}