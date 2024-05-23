pragma solidity ^0.8.0;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IAsset {
    function initialize (address _uniV3PoolAddress, int56[7] memory _priceHistory, address _swapRouter) external;
    function writeMostRecentPrice() external;
    function mostRecentSharpe() external view returns (int);
    function mostRecentSTD() external view returns (uint);
    function mostRecentReturn() external view returns (int);
    function mostRecentPriceUpdateTime() external view returns (uint);
    function swap(uint256 amountIn, bool usingUSDC) external returns (uint256 amountOut);

}