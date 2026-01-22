import {
  time,
  loadFixture,
  setBalance,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { impersonateAccount } from "@nomicfoundation/hardhat-toolbox/network-helpers";

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
      ).to.be.revertedWith("Trading is not active.");
    });

    it("开启交易后 普通用户可以转账", async function () {
      const { token, user1, user2 } = await loadFixture(deployTokenFixture);
      await token.transfer(user1.address, ethers.parseEther("1000"));
      await token.enableTrading();

      await token
        .connect(user1)
        .transfer(user2.address, ethers.parseEther("100"));

      expect(await token.balanceOf(user1.address)).to.be.equal(
        ethers.parseEther("900"),
      );
      expect(await token.balanceOf(user2.address)).to.be.equal(
        ethers.parseEther("100"),
      );
    });
  });

  describe("3. 税收逻辑测试", function () {
    it("白名单转账没有税", async function () {
      const { user1, token } = await loadFixture(deployTokenFixture);
      await token.enableTrading();
      await token.transfer(user1.address, ethers.parseEther("100"));

      expect(await token.balanceOf(user1.address)).to.be.equal(
        ethers.parseEther("100"),
      );
    });

    it("模拟买入（从池子到用户），应该扣除5%的买入税", async function () {
      const { user1, token } = await loadFixture(deployTokenFixture);
      const pairAddress = await token.pair();
      await token.enableTrading();
      // 接管这个账号 因为pair是合约的地址 我们是获取不到私钥 user owner是hardhat提供的 知道私钥
      await impersonateAccount(pairAddress);
      // 获取pair的签名者
      const pairSigner = await ethers.getSigner(pairAddress);

      // 添加池子
      await token.transfer(pairAddress, ethers.parseEther("10000"));
      // 因为发起转账不仅需要有token 还需要有gas 所以借助setBalance给该账户设置gas
      await setBalance(pairAddress, ethers.parseEther("100"));

      // 模拟pair向user1转账就是买入了
      await token
        .connect(pairSigner)
        .transfer(user1.address, ethers.parseEther("100"));

      expect(await token.balanceOf(user1.address)).to.be.equal(
        ethers.parseEther("95"),
      );
    });

    it("模拟卖出（从用户到池子），应该扣除10%的税", async function () {
      const { token, user1 } = await loadFixture(deployTokenFixture);

      await token.enableTrading();

      await token.transfer(user1.address, ethers.parseEther("1000"));

      const pairAddress = await token.pair();

      await token
        .connect(user1)
        .transfer(pairAddress, ethers.parseEther("1000"));

      expect(await token.balanceOf(pairAddress)).to.be.equal(
        ethers.parseEther("900"),
      );
    });
  });

  describe("4.限制和黑名单测试", function () {
    it("每个钱包最大持仓限制, 模拟从池子里面买入", async function () {
      const { token, user1 } = await loadFixture(deployTokenFixture);

      // 往池子里面注入资金
      const pairAddress = await token.pair();

      await impersonateAccount(pairAddress);

      const pairSigner = await ethers.getSigner(pairAddress);

      await token.transfer(pairAddress, ethers.parseEther("100000000"));
      await setBalance(pairAddress, ethers.parseEther("100"));

      await token.enableTrading();

      const maxWallet = await token.maxWalletAmount();

      await expect(
        token
          .connect(pairSigner)
          .transfer(user1.address, maxWallet + ethers.parseEther("1")),
      ).to.be.revertedWith("Buy amount exceeds maxTxAmount");
    });

    it("黑名单测试", async function () {
      const { token, user1, user2 } = await loadFixture(deployTokenFixture);
      await token.enableTrading();
      await token.transfer(user1.address, ethers.parseEther("100"));

      // 将user1设置为黑名单
      await token.setBlacklist(user1.address, true);

      // 因为user1被设置为了黑名单 所以无法转账等操作

      await expect(
        token.connect(user1).transfer(user2.address, ethers.parseEther("10"))
      ).to.be.revertedWith("Address is blacklisted");
    });
  });
});
