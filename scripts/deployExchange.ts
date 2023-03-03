import { ethers } from "hardhat";

async function main() {
  const ProxyRegistry = await ethers.getContractFactory("ProxyRegistry");
  const proxyRegistry = await ProxyRegistry.deploy();

  await proxyRegistry.deployed();

  console.log("Proxy Registry Address : ", proxyRegistry.address);

  const Exchange = await ethers.getContractFactory("NFTExchange");
  const exchange = await Exchange.deploy(
    "0x1C20d5826e2204aEcbD0e2887024CE6B43506B52",
    proxyRegistry.address
  );

  await exchange.deployed();

  console.log("NFT Exchange", exchange.address);

  await proxyRegistry.functions.grantAuthentication(exchange.address);
  console.log("Allow exchange to use proxy contracts sucessfully!");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
