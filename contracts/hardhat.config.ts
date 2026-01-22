import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";                   // 3. 读取 .env 文件的环境变量
dotenv.config();
const config: HardhatUserConfig = {
  solidity: "0.8.28",
  networks:{
    bscTestnet: {
      url: "https://shy-indulgent-sea.bsc-testnet.quiknode.pro/96e4afdcaa06ddf90485028982b3e5227c79e17b/",
      chainId: 97,
      accounts: [process.env.PRIVATE_KEY!]
    }
  }
};

export default config;
