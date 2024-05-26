// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/uniswap-interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IAsset.sol";

contract Asset is IAsset, IUniswapV3SwapCallback {

    bool initialized = false;

    ISwapRouter public swapRouter;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public assetTokenAddress;
    
    //vars
    address public uniV3PoolAddress;
    int56[7] public priceHistory;
    int256 public mostRecentSharpe;
    uint256 public mostRecentSTD;
    int256 public mostRecentReturn;
    uint256 public mostRecentPriceUpdateTime;

    //constructor
    constructor() {}

    //modifiers
    modifier onlyInitialized() {
        require(initialized, "Contract not initialized");
        _;
    }

    function initialize (address _uniV3PoolAddress, int56[7] memory _priceHistory, address _swapRouter) public {
        initialized = true;

        swapRouter = ISwapRouter(_swapRouter);

        uniV3PoolAddress = _uniV3PoolAddress;

        if (IUniswapV3Pool(uniV3PoolAddress).token1() == USDC) {
            assetTokenAddress = IUniswapV3Pool(uniV3PoolAddress).token0();
        } else if (IUniswapV3Pool(uniV3PoolAddress).token0() == USDC) {
            assetTokenAddress = IUniswapV3Pool(uniV3PoolAddress).token1();
        } else {
            revert("USDC not in pool");
        }

        priceHistory = _priceHistory;
        mostRecentPriceUpdateTime = block.timestamp;
        updateSharpe();
    }

    // Functions
    /// @notice Writes the most recent price to the price history array and updates the Sharpe ratio
    /// @dev This function can only be called once per day
    function writeMostRecentPrice() public onlyInitialized {
        // Ensure the function can only be called once per day
        require(block.timestamp - mostRecentPriceUpdateTime > 86400, "Price can only be updated once a day");

        // Calculate the average tick over the last hour
        int56 averageTick = getPrice();

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

    /// @notice Updates the Sharpe ratio based on the price history
    /// @dev The Sharpe ratio is calculated using the daily returns of the asset and a daily risk-free rate
    function updateSharpe() public onlyInitialized {
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
        uint256 standardDeviation = Math.sqrt(variance);

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


    /// @notice swapExactInputSingle swaps a fixed amount of TOKEN_IN for a maximum possible amount of TOKEN_OUT
    /// using the USDC/Asset 0.3% pool by calling `exactInputSingle` in the swap router.
    /// @dev The calling address must approve this contract to spend at least `amountIn` worth of its USDC for this function to succeed.
    /// @param amountIn The exact amount of USDC that will be swapped for Asset.
    /// @return amountOut The amount of Asset received.
    function swap(uint256 amountIn, bool usingUSDC) external onlyInitialized returns (uint256 amountOut){

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
        require(IERC20(TOKEN_IN).allowance(msg.sender, address(this)) >= amountIn, "Insufficient allowance");

        // Transfer the specified amount of TOKEN_IN to this contract.
        TransferHelper.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);

        TransferHelper.safeApprove(TOKEN_IN, address(uniV3PoolAddress), amountIn);

        IUniswapV3Pool pool = IUniswapV3Pool(uniV3PoolAddress);
        address recipient = msg.sender;
        bool zeroForOne = !usingUSDC;
        int256 amountSpecified = int256(amountIn);
        int56 averageTick = getPrice();
        uint160 sqrtPriceLimitX96 = uint160(Math.sqrt(uint256(int256(averageTick))) * 2**96);

        pool.swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, abi.encode(0));
    }

    /// @notice returns the avg tick over the last hour, always in USD
    /// @dev Conversion to USD is done via the token1IsUSDC bool
    function getPrice() public view onlyInitialized returns (int56) {
        //Instantiate the pool
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

        return averageTick;
    }

    // Getters
    function getUniPoolInfo() public view onlyInitialized returns (int56, address, address, address, uint24, int24, uint128) {
        IUniswapV3Pool uniV3Pool = IUniswapV3Pool(uniV3PoolAddress);

        int56 averageTick = getPrice();

        return (averageTick, uniV3Pool.factory(), uniV3Pool.token0(), uniV3Pool.token1(), uniV3Pool.fee(), uniV3Pool.tickSpacing(), uniV3Pool.maxLiquidityPerTick());
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override onlyInitialized {
        // Ensure the callback is coming from the correct pool
        require(msg.sender == uniV3PoolAddress, "Unauthorized callback");
        // Handle the swap amounts
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(uniV3PoolAddress).token0()).transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(uniV3PoolAddress).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

}