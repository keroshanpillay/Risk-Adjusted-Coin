import { time, loadFixture } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre from "hardhat";
import { getAddress, parseGwei } from "viem";
import erc20abi from './erc20abi.json';

describe("Asset", function () {
  //params for the asset
  const uniV3PoolAddress = "0x9a772018FbD77fcD2d25657e5C547BAfF3Fd7D16";
  const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const swapRouterAddress = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";
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

    return { asset, owner, otherAccount, publicClient };
  }

  describe("Deployment", function () {
    it("Get USDC on the chain", async function () {
        const {owner, publicClient} = await loadFixture(deployAsset);
        const usdcDecimals = await publicClient.readContract({address:USDC, abi:erc20abi, functionName:"decimals"});
        expect(usdcDecimals).to.equal(6);
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

  });
});