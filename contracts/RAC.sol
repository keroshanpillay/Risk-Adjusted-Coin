pragma solidity ^0.8.0;

import './Asset.sol';
import '../interfaces/IAsset.sol';

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/uniswap-interfaces/IUniswapV3Pool.sol";

contract RAC {
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant SWAP_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    mapping(address => address) public getAsset;
    address[] public allAssets;

    int256[] public sharpeRatios;
    uint[] public weights;

    uint public lastInfoUpdateTime;
    uint public lastRebalanceTime;

    constructor() {
        weights = new uint[](1);
        lastInfoUpdateTime = 0;
    }

    event AssetCreated(address _uniV3PoolAddress, uint _assetIndex);

    function allAssetsLength() external view returns (uint) {
        return allAssets.length;
    }

    function getSharpeRatios() private {
        for (uint i = 0; i < allAssets.length; i++) {
            Asset asset = Asset(allAssets[i]);
            sharpeRatios.push(asset.mostRecentSharpe());
        }
    }

    function sharpesToWeights() private {
        require(weights.length == sharpeRatios.length + 1, "Weights array must be 1 longer than sharpeRatios array");

        int256 totalSharpe = 0;
        for (uint i = 0; i < sharpeRatios.length; i++) {
            int curr_sharpe = sharpeRatios[i];
            curr_sharpe >= 0 ? curr_sharpe : -curr_sharpe; // absolute value
            totalSharpe += curr_sharpe;
        }
        for (uint i = 0; i < sharpeRatios.length; i++) {
            if (sharpeRatios[i] < 0) {
                weights[0] += uint(-sharpeRatios[i] / totalSharpe);
            }
            weights[i+1] = uint(sharpeRatios[i] / totalSharpe);
        }
    }

    function dailyPullForAllAssets () external {
        //this can only happen once a day
        require(block.timestamp - lastInfoUpdateTime > 86400, "Price can only be updated once a day");

        for (uint i = 0; i < allAssets.length; i++) {
            Asset(allAssets[i]).writeMostRecentPrice();
        }

        //internally, update our sharpes and weights
        getSharpeRatios();
        sharpesToWeights();

        //update the updated time
        lastInfoUpdateTime = block.timestamp;
    }

    function createAsset(address _uniV3PoolAddress, int56[7] memory _priceHistory) external returns (address asset) {
        //constrain time -- if first asset, set lastInfoUpdateTime to now
        if (lastInfoUpdateTime == 0) {
            lastInfoUpdateTime = block.timestamp;
        } else {
            //you can only add a new asset within 10 minutes of the most recent asset addition
            require(block.timestamp - lastInfoUpdateTime < 600, "10min time constraint between asset additions and data pulls");
        }

        //can't have the same asset
        require(getAsset[_uniV3PoolAddress] == address(0), 'ASSET_EXISTS');

        //create2 it
        bytes memory bytecode = type(Asset).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_uniV3PoolAddress));
        assembly {
            asset := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IAsset(asset).initialize(_uniV3PoolAddress, _priceHistory, SWAP_ROUTER);
        getAsset[_uniV3PoolAddress] = asset;
        getAsset[asset] = _uniV3PoolAddress;
        allAssets.push(asset);
        emit AssetCreated(_uniV3PoolAddress, allAssets.length);

        //make weights array bigger by 1
        weights = new uint[](weights.length + 1);
    }

    function rebalance() external {
        //time requirement
        require(block.timestamp - lastRebalanceTime > 7*86400, "Rebalance can only happen once a week");
        // require(block.timestamp - lastInfoUpdateTime < 600, "10min time constraint between rebalances and data pulls");
    
        //sell all the assets for usdc
        for (uint i = 0; i < allAssets.length; i++) {
            //get the balance of the contract for the token (non-usdc)
            uint contractBalanceForToken = IERC20(Asset(allAssets[i]).assetTokenAddress()).balanceOf(allAssets[i]);
            //swap it for usdc
            Asset(allAssets[i]).swap(contractBalanceForToken, false);
        }

        uint totalUsdc = IERC20(USDC).balanceOf(address(this));

        //using the weights, buy the assets proportionally.
        //the first asset in the weights is always usdc, so we don't need to buy that
        for (uint i = 0; i < allAssets.length; i++) {
            Asset(allAssets[i]).swap(totalUsdc * weights[i+1] / 100, true);
        }

        //update the updated time
        lastRebalanceTime = block.timestamp;
    }


}