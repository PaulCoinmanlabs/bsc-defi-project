import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";
const ROUTER_ADDRESS = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1";

const TokenModule = buildModule("TokenModule", (m) => {
  const deployer = m.getAccount(0);

  const token = m.contract("UltimateBSCCoin", [ROUTER_ADDRESS, deployer]);

  return { token };
});

export default TokenModule;
