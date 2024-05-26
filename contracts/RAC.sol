// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './Asset.sol';
import '../interfaces/IAsset.sol';

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RAC is ERC20 {
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    mapping(address => address) public getAsset;
    address[] public allAssets;

    int256[] public sharpeRatios;
    uint[] public weights;

    uint private lastInfoUpdateTime;
    uint private lastRebalanceTime;
    bool internal initialized;

    uint256 public treasuryValueUSD;
    uint256[] public mostRecentAssetPrices;

    /// @notice create the RAC contract
    /// @dev come back the next day and add your first asset
    /// come back every day after that and update prices
    constructor() ERC20("RAC", "RAC") {
        weights = new uint[](1);
    }

    //modifiers
    modifier onlyInitialized() {
        require(initialized, "Contract not initialized");
        _;
    }

    /// @notice Initializes the contract
    /// @dev This function is only called once -- when the contract is deployed
    /// Have to do the constructor-initializer pattern because of the approve in USDC
    function initialize() external {
        //transfer USDC to the contract
        IERC20(USDC).transferFrom(msg.sender, address(this), 1000e6);

        //mint the RAC tokens -- 1:1 with USDC
        _mint(msg.sender, 1000e18);

        //initialized
        initialized = true;

        //update
        _updateAllAssetInfo();
        _rebalance();
    }

    /// @notice Mints RAC tokens with USD
    /// @param amountUSD The amount of USD to mint RAC with
    /// @dev USDC is always the input token -- you need USDC
    function mintWithUSD (uint256 amountUSD) external onlyInitialized() returns (uint256 amountRAC) {
        //caller needs to have approved the contract to spend their USDC
        require(IERC20(USDC).allowance(msg.sender, address(this)) >= amountUSD, "MINT:ALLOW");

        //transfer the USDC from the sender to the contract
        IERC20(USDC).transferFrom(msg.sender, address(this), amountUSD);

        //calculate the amount of RAC to mint
        getMostRecentTreasuryValue();
        amountRAC = amountUSD * totalSupply() / treasuryValueUSD;

        //mint the RAC tokens
        _mint(msg.sender, amountRAC);

        uint256 amountUSDLeft = amountUSD;

        //buy the assets with the USDC
        for (uint i = 0; i < allAssets.length; i++) {
            //approve the asset to spend the usdc
            IERC20(USDC).approve(allAssets[i], (amountUSD * weights[i+1]) / 1e18);
            //swap the usdc for the asset
            Asset(allAssets[i]).swap((amountUSD * weights[i+1]) / 1e18, true);
            //update the amount of usdc left
            amountUSDLeft -= (amountUSD * weights[i+1]) / 1e18;
        }

        //the remainder of USDC should be the weight of USDC
        require(amountUSDLeft == (amountUSD * weights[0]) / 1e18, "MINT:USDC");

        return amountUSD;
    }

    ///@notice updates the value of the treasury
    function getMostRecentTreasuryValue() private onlyInitialized() {
        treasuryValueUSD = 0;
        //calculate the most recent prices of all our assets 
        for (uint i = 0; i < allAssets.length; i++) {
            treasuryValueUSD += uint256(int256(Asset(allAssets[i]).getPrice()))*IERC20(Asset(allAssets[0]).assetTokenAddress()).balanceOf(address(this));
        }
    }

    event AssetCreated(address _uniV3PoolAddress, uint _assetIndex);

    function allAssetsLength() external view returns (uint) {
        return allAssets.length;
    }

    function updateSharpeRatios() private onlyInitialized() {
        for (uint i = 0; i < allAssets.length; i++) {
            Asset asset = Asset(allAssets[i]);
            sharpeRatios.push(asset.mostRecentSharpe());
        }
    }

    /// @notice Converts the sharpe ratios to weights -- the weights are scaled by 1e18
    /// @dev whenever using the weights, critical to divide by 1e18
    function sharpesToWeights() private onlyInitialized() {
        require(weights.length == sharpeRatios.length + 1, "S2W:LENGTH");

        int256 totalSharpe = 0;
        for (uint i = 0; i < sharpeRatios.length; i++) {
            int curr_sharpe = sharpeRatios[i];
            curr_sharpe >= 0 ? curr_sharpe : -curr_sharpe; // absolute value
            totalSharpe += curr_sharpe;
        }

        //calculate the weights
        for (uint i = 0; i < sharpeRatios.length; i++) {
            if (sharpeRatios[i] < 0) {
                weights[0] += uint((-sharpeRatios[i]*1e18) / totalSharpe);
            }
            weights[i+1] = uint((sharpeRatios[i]*1e18) / totalSharpe);
        }
    }

    function _updateAllAssetInfo () private onlyInitialized() {
        //update the updated time
        lastInfoUpdateTime = block.timestamp;

        if (allAssets.length == 0) {
            return;
        }
        //write the most recent price for all assets (stored in the Asset contract)
        for (uint i = 0; i < allAssets.length; i++) {
            Asset(allAssets[i]).writeMostRecentPrice();
        }

        //internally, update our sharpes and weights
        updateSharpeRatios();
        sharpesToWeights();

        if (block.timestamp - lastRebalanceTime == 604800) {
            _rebalance();
        }
    }

    function createAsset(address _uniV3PoolAddress, int56[7] memory _priceHistory) external onlyInitialized() returns (address asset) {
        //constrain time -- if first asset, set lastInfoUpdateTime to now
        require(((block.timestamp - lastInfoUpdateTime) % 86400) == 0, "ADDASSET:TIME");

        //can't have the same asset
        require(getAsset[_uniV3PoolAddress] == address(0), 'ADDASSET:DUP');

        //create2
        bytes memory bytecode = type(Asset).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_uniV3PoolAddress));
        assembly {
            asset := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IAsset(asset).initialize(_uniV3PoolAddress, _priceHistory);
        getAsset[_uniV3PoolAddress] = asset;
        getAsset[asset] = _uniV3PoolAddress;
        allAssets.push(asset);
        emit AssetCreated(_uniV3PoolAddress, allAssets.length);

        //make weights array bigger by 1
        weights = new uint[](weights.length + 1);

        //update all assets
        _updateAllAssetInfo();

    }

    function _rebalance() private onlyInitialized() {
        //time requirement
        require(block.timestamp == lastInfoUpdateTime, "REBAL:TIME");
        
        if (allAssets.length == 0) {
            return;
        }
    
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
            //approve the asset to spend the usdc
            IERC20(USDC).approve(allAssets[i], (totalUsdc * weights[i+1]) / 1e18);
            //swap the usdc for the asset
            Asset(allAssets[i]).swap((totalUsdc * weights[i+1]) / 1e18, true);
        }

        //update the updated time
        lastRebalanceTime = block.timestamp;
    }

    /// @notice Burns RAC tokens for USD
    /// @param amountRAC The amount of RAC to burn
    /// @dev Assets in the basket are sold proportionally to their weights to make up the amount of USD
    function burnToUSD(uint256 amountRAC) external onlyInitialized() returns (uint256 amountUSD) {

        //burn the RAC tokens
        _burn(msg.sender, amountRAC);

        //calculate the amount of USD to burn
        getMostRecentTreasuryValue();
        amountUSD = amountRAC * treasuryValueUSD / totalSupply();

        //sell the assets for USDC, by their weight to make up the amount of USD
        for (uint i = 0; i < allAssets.length; i++) {
            //get balance before -- we will use for a safety check
            uint256 contractBalanceForToken = IERC20(Asset(allAssets[i]).assetTokenAddress()).balanceOf(allAssets[i]);
            //calculate the amount of the token to sell
            uint256 amountTokenToSell = (amountUSD * weights[i+1] / (1e18*uint256(int256(Asset(allAssets[i]).getPrice()))));
            //swap the token for usdc
            Asset(allAssets[i]).swap(amountTokenToSell, false);
            //get balance after
            uint256 contractBalanceForTokenAfter = IERC20(Asset(allAssets[i]).assetTokenAddress()).balanceOf(allAssets[i]);
            //check that the amount of the token sold is correct
            assert(contractBalanceForToken-contractBalanceForTokenAfter == amountTokenToSell);
        }

        IERC20(USDC).transfer(msg.sender, amountUSD);

        return amountUSD;
    }


}