import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre from "hardhat";
import { getAddress, parseGwei } from "viem";
import erc20abi from './erc20abi.json';
import { impersonateAccount } from "@nomicfoundation/hardhat-network-helpers"

describe("Asset", function () {
  //params for the asset
  const uniV3PoolAddress = "0x9a772018FbD77fcD2d25657e5C547BAfF3Fd7D16";
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const swapRouterAddress = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45";
  const priceArrayDollars = [65994.02, 65236.23, 66889.66, 66682.11, 66200.33, 71503.0, 69501.15];
//   const priceArrayDollars = [3025, 2946, 3087, 3117, 3071, 3659, 3000];
    const multiplier = 1;
  const priceArrayUSDC: [bigint, bigint, bigint, bigint, bigint, bigint, bigint] = [
    BigInt(Math.floor(priceArrayDollars[0] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[1] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[2] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[3] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[4] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[5] * multiplier)),
    BigInt(Math.floor(priceArrayDollars[6] * multiplier)),
  ];

  console.log(priceArrayUSDC);

  async function deployAsset() {
    const [owner, otherAccount] = await hre.viem.getWalletClients();
    const asset = await hre.viem.deployContract("Asset", []);
    const publicClient = await hre.viem.getPublicClient();

    //initialize the asset
    await asset.write.initialize([uniV3PoolAddress, priceArrayUSDC, swapRouterAddress]);

    const mostRecentSharpe = await asset.read.mostRecentSharpe();
    console.log("Most recent Sharpe ratio: ")
    console.log(mostRecentSharpe);
    console.log("Return: ");
    console.log(await asset.read.mostRecentReturn());
    console.log("STD: ");
    console.log(await asset.read.mostRecentSTD());

    // Impersonate a USDC whale
    const whaleAddress = "0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa"; 
    await impersonateAccount(whaleAddress);
    const [whaleWalletClient] = await hre.viem.getWalletClients({account: whaleAddress});

    const whaleBalance = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"balanceOf", args:[whaleAddress]});

    // Transfer USDC from whale to owner
    console.log("Whale balance: ");
    console.log(whaleBalance);
    await whaleWalletClient.writeContract({address:USDC, abi:erc20abi, functionName:"transfer", args:[owner.account.address, whaleBalance]});

    return { asset, owner, otherAccount, publicClient };
  }

  describe("Deployment", function () {
    it("Get USDC on the chain", async function () {
        const {owner, publicClient} = await loadFixture(deployAsset);
        const usdcDecimals = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"decimals"});
        expect(usdcDecimals).to.equal(6);

        // Check that we have the USDC
        // const whaleAddress = "0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa"; 
        // const whaleBalance = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"balanceOf", args:[whaleAddress]});
        // const ownerBalance = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"balanceOf", args:[owner.account.address]});
        // expect(ownerBalance).to.equal(whaleBalance);
    });
    it("Should deploy", async function () {
      const { asset, owner } = await loadFixture(deployAsset);
      expect(asset.address).to.not.be.undefined;
      expect(await asset.read.priceHistory([BigInt(0)])).to.equal(priceArrayUSDC[0]);
      console.log(await asset.read.getUniPoolInfo());
    });
    it("Should update price", async function () {
        const { asset, owner } = await loadFixture(deployAsset);
        //forward the time by 1 day
        await time.increase(time.duration.days(1));
        await asset.write.writeMostRecentPrice();
        console.log(await asset.read.priceHistory([BigInt(6)]));
        expect(await asset.read.priceHistory([BigInt(0)])).to.equal(priceArrayUSDC[1]);
    });
    it("Should swap to WBTC correctly", async function () {
        const { asset, owner, publicClient } = await loadFixture(deployAsset);
        const wbtc = await asset.read.assetTokenAddress();

        const AMT_TO_SWAP = BigInt(70000*10**6);

        //get balance before
        const usdcBalanceBefore = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"balanceOf", args:[owner.account.address]});
        const wbtcBalanceBefore = await publicClient.readContract({address:wbtc, abi:erc20abi, functionName:"balanceOf", args:[owner.account.address]});
        console.log("USDC balance before: ");
        console.log(usdcBalanceBefore);
        console.log("WBTC balance before: ");
        console.log(wbtcBalanceBefore);

        //approve the spend of USDC by owner
        await owner.writeContract({address:USDC, abi:erc20abi, functionName:"approve", args:[asset.address, AMT_TO_SWAP]});

        //swap 1000 USDC to WBTC
        await asset.write.swap([AMT_TO_SWAP, true]);

        //get balance after
        const usdcBalanceAfter = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"balanceOf", args:[owner.account.address]});
        const wbtcBalanceAfter = await publicClient.readContract({address:wbtc, abi:erc20abi, functionName:"balanceOf", args:[owner.account.address]});

        //log

        console.log("USDC balance after: ");
        console.log(usdcBalanceAfter);

        console.log("WBTC balance after: ");
        console.log(wbtcBalanceAfter);
    });
  });
});