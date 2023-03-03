// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./AuthenticatedProxy.sol";

contract ProxyRegistry is Ownable {
  mapping (address => bool) public contracts;
  mapping (address => address) public proxies;

  function grantAuthentication(address addr) external onlyOwner { 
    require(!contracts[addr], "Already registered");
    contracts[addr] = true;
  }

  function revokeAuthentication(address addr) external onlyOwner {
    require(contracts[addr], "Not registered");
    delete contracts[addr];
  }

  function registerProxy() external returns(AuthenticatedProxy proxy) {
    require(proxies[msg.sender] == address(0), "Already registered");
    proxy = new AuthenticatedProxy(msg.sender);
    proxies[msg.sender] = address(proxy);
    return proxy;
  }
}
