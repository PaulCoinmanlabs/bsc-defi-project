import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import hre, { ethers } from "hardhat";

describe("UltimateBSCCoin Test", function () {
  async function deployTokenFixture() {
    const [owner, marketingWallet, user1, user2, treasury] =
      await ethers.getSigners();

    const MockWETH = await ethers.getContractFactory("MockWETH");
    const weth = await MockWETH.deploy();

    const MockFactory = await ethers.getContractFactory("MockFactory");
    const factory = await MockFactory.deploy();

    const MockRouter = await ethers.getContractFactory("MockRouter");
    const router = await MockRouter.deploy(
      await factory.getAddress(),
      await weth.getAddress(),
    );

    const Token = await ethers.getContractFactory("UltimateBSCCoin");
    const token = await Token.deploy(
      await router.getAddress(),
      marketingWallet.address,
    );

    const pairAddress = await token.pair();
    return { router, token, pairAddress, owner, marketingWallet, user1, user2 };
  }

  describe("1. 基础部署测试", function () {
    it("Token的基本信息", async function () {
      const { token } = await loadFixture(deployTokenFixture);
      expect(await token.name()).to.be.equal("Ultimate Moon");
      expect(await token.symbol()).to.be.equal("UMOON");
    });

    it("所有的代币都在部署者的手上", async function () {
      const { token, owner } = await loadFixture(deployTokenFixture);
      const totalSupply = await token.totalSupply();
      expect(await token.balanceOf(owner.address)).to.be.equal(totalSupply);
    });
  });

  describe("2. 交易开关测试", function () {
    it("未开盘前，普通用户之间不允许转账", async function () {
      const { token, user1, user2 } = await loadFixture(deployTokenFixture);
      await token.transfer(user1.address, ethers.parseEther("1000"));
      await expect(
        token.connect(user1).transfer(user2.address, ethers.parseEther("100")),
      ).to.be.revertedWith("Trading is not active");
    });

    it("开启交易后 普通用户可以转账", async function () {
      const { token, user1, user2 } = await loadFixture(deployTokenFixture);
      await token.transfer(user1.address, ethers.parseEther("1000"));
      await token.enableTrading();

      await token.connect(user1).transfer(user2.address, ethers.parseEther("100"));

      expect(await token.balanceOf(user1.address)).to.be.equal(
        ethers.parseEther("900"),
      );
      expect(await token.balanceOf(user2.address)).to.be.equal(
        ethers.parseEther("100"),
      );
    });
  });
});
