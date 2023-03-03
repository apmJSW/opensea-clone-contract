// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./structures/Order.sol";

import "./interfaces/IProxyRegistry.sol";
import "./interfaces/IProxy.sol";

struct Sig {
  bytes32 r;
  bytes32 s;
  uint8 v;
}

contract NFTExchange is Ownable, ReentrancyGuard {
  bytes32 private constant ORDER_TYPEHASH = 0x7d2606b3242cc6e6d31de9a58f343eed0d0647bd06fe84c19441d47d44316877;

  address public feeAddress;
  mapping (bytes32 => bool) public cancelledOrFinalized;
  IProxyRegistry proxyRegistry;

  event OrderMatched(
    bytes32 buyHash,
    bytes32 sellHash,
    address indexed maker,
    address indexed taker,
    uint256 price
  );

  constructor(address feeAddress_, address proxyRegistry_) {
    feeAddress = feeAddress_;
    proxyRegistry = IProxyRegistry(proxyRegistry_);
  }

  function setFeeAddress(address feeAddress_) external onlyOwner {
    feeAddress = feeAddress_;
  }

  function atomicMatch(Order memory buy, Sig memory buySig, Order memory sell, Sig memory sellSig) external nonReentrant {
    bytes32 buyHash = validateOrder(buy, buySig);
    bytes32 sellHash = validateOrder(sell, sellSig);

    require(ordersCanMatch(buy, sell), "not matched");

    require(!cancelledOrFinalized[buyHash] && !cancelledOrFinalized[sellHash], 'finalized order');

    require(isContract(sell.target)); 

    if (buy.replacementPattern.length > 0) {
      guardedArrayReplace(buy.calldata_, sell.calldata_, buy.replacementPattern);
    }
    if (sell.replacementPattern.length > 0) {
      guardedArrayReplace(sell.calldata_, buy. calldata_, sell.replacementPattern);
    }
    require(keccak256(buy.calldata_) == keccak256(sell.calldata_));

    cancelledOrFinalized[buyHash] = true;
    cancelledOrFinalized[sellHash] = true;

    uint256 price = executeFundsTransfer(buy, sell);

    IProxy proxy = IProxy(proxyRegistry.proxies(sell.maker));

    require(proxy.proxy(sell.target, sell.calldata_));

    if (buy.staticTarget != address(0)) {
     require(staticCall(buy.target, buy.calldata_, buy.staticExtra));
    }

    if (sell.staticTarget != address(0)) {
     require(staticCall(sell.target, sell.calldata_, sell.staticExtra));
    }

    emit OrderMatched(
      buyHash,
      sellHash,
      msg.sender == sell.maker ? sell.maker : buy.maker,
      msg.sender == sell.maker ? buy.maker : sell.maker,
      price
    );
  }

  function isContract(address target) internal view returns (bool) {
    uint size;
    assembly {
      size := extcodesize(target)
    }
    return size > 0;
  }

  function calculateMatchPrice(Order memory buy, Order memory sell) internal view returns (uint256) {
    uint256 buyPrice = getOrderPrice(buy);
    uint256 sellPrice = getOrderPrice(sell);

    require(buyPrice >= sellPrice);

    return buyPrice;
  }

  function getOrderPrice(Order memory order) internal view returns (uint256) {
    if (order.saleKind == SaleKind.FIXED_PRICE) {
      return order.basePrice;
    }
    if (order.basePrice > order.endPrice) {
      return order.basePrice - 
      ((block.timestamp - order.listingTime) 
      * (order.basePrice - order.endPrice) 
      / (order.expirationTime - order.listingTime));
    }
    if (order.basePrice < order.endPrice) {
      return order.saleSide == SaleSide.SELL ? order.basePrice : order.endPrice;
    }
  }

  function getFeePrice(uint256 price) internal pure returns (uint256) {
    return price / 40;
  }
  
  function executeFundsTransfer(Order memory buy, Order memory sell) internal returns (uint256 price) {
    // 이더로 구매하는 게 아닌 경우
    if (sell.paymentToken != address(0)) {
      require(msg.value == 0);
    }

    price = calculateMatchPrice(buy, sell);
    uint256 fee = getFeePrice(price);

    if (price <= 0) {
      return 0;
    }

    if (sell.paymentToken != address(0)) {
      IERC20(sell.paymentToken).transferFrom(buy.maker, sell.maker, price);
      IERC20(sell.paymentToken).transferFrom(buy.maker, sell.maker, fee);
    } else {
      // 이더를 전송해야 하는 경우
      require(msg.sender == buy.maker);

      (bool result,) = sell.maker.call{value: price}("");
      require(result);
      (result,) = feeAddress.call{value:fee}("");
      require(result);

      uint256 remain = msg.value - price - fee;
      if (remain > 0) {
        (result,) = msg.sender.call{value: remain}("");
      }
    }
  }

  function ordersCanMatch(Order memory buy, Order memory sell) internal view returns (bool) {
    // Sell to highest bidder 방식일 경우에는 seller만 트랜잭션 호출 가능.
    // 누군가가 최고가보다 낮은 가격에 주문을 생성하고, 트랜잭션을 보내는 것을 방지하기 위해.
    if ( sell.saleKind == SaleKind.AUCTION && sell.basePrice <= sell.endPrice) {
      require(msg.sender == sell.maker);
    }

    return (buy.taker == address(0) || buy.taker == sell.maker) 
    && (sell.taker == address(0) || sell.taker == buy.maker)
    && (buy.saleSide == SaleSide.BUY && sell.saleSide == SaleSide.SELL)
    && (buy.saleKind == sell.saleKind)
    && (buy.target == sell.target)
    && (buy.paymentToken == sell.paymentToken)
    && (buy.basePrice == sell.basePrice)
    // basePrice > endPrice의 경우, sell with declining price 방식이므로 endPrice가 동일해야 한다.
    && (sell.saleKind == SaleKind.FIXED_PRICE 
        || sell.basePrice <= sell.endPrice 
        || (buy.endPrice == sell.endPrice)) && 
      (canSettleOrder(buy) && canSettleOrder(sell));
  }

  function canSettleOrder(Order memory order) internal view returns (bool) {
    return (order.listingTime <= block.timestamp) && (order.expirationTime == 0 || order.expirationTime >= block.timestamp);
  }

  function validateOrder(Order memory order, Sig memory sig) internal view returns (bytes32 orderHash) {
    if (msg.sender != order.maker) {
      orderHash = validateOrderSig(order, sig);
    }

    require(order.exchange == address(this));

    if (order.saleKind == SaleKind.AUCTION) {
      require(order.expirationTime > order.listingTime);
    }
  }

  function validateOrderSig(Order memory order, Sig memory sig) internal pure returns (bytes32 orderHash) {
    orderHash = hashOrder(order);

    require(ecrecover(orderHash, sig.v, sig.r, sig.s) == order.maker);
  }

  function hashOrder(Order memory order) public pure returns (bytes32) {
    return 
      keccak256(
        abi.encodePacked(
          abi.encode(
            ORDER_TYPEHASH, 
            order.exchange, 
            order.maker, 
            order.taker,
            order.saleSide, 
            order.saleKind, 
            order.target, 
            order.paymentToken, 
            keccak256(order.calldata_), 
            keccak256(order.replacementPattern),
            order.staticTarget,
            keccak256(order.staticExtra)
          ),
          abi.encode(
            order.basePrice, 
            order.endPrice, 
            order.listingTime, 
            order.expirationTime, 
            order.salt)
        )
      );
  }

  function guardedArrayReplace(bytes memory array, bytes memory desired, bytes memory mask) internal pure {
    require(array.length == desired.length);
    require(array.length == mask.length);

    uint words = array.length / 0x20;
    uint index = words * 0x20;
    assert(index / 0x20 == words);
    uint i;
    for (i = 0; i < words; i++) {
      assembly {
        let commonIndex := mul(0x20, add(1, i))
        let maskValue := mload(add(mask, commonIndex))
        mstore(add(array, commonIndex), or(and(not(maskValue), mload(add(array, commonIndex))), and(maskValue, mload(add(desired, commonIndex)))))
      }
    }

    if (words > 0) {
      i = words;
      assembly {
        let commonIndex :=mul(0x20, add(1, i))
        let maskValue := mload(add(mask, commonIndex))
        mstore(add(array, commonIndex), or(and(not(maskValue), mload(add(array, commonIndex))), and(maskValue, mload(add(desired, commonIndex)))))
      }
    } else {
      for (i = index; i < array.length; i++) {
        array[i] = ((mask[i] ^ 0xff) & array[i]) | (mask[i] & desired[i]);
      }
    }
  }

  function staticCall(address target, bytes memory calldata_, bytes memory extraCalldata) internal view returns (bool result) {
    bytes memory combined = bytes.concat(extraCalldata, calldata_);
    uint256 combinedSize = combined.length;

    assembly {
      result := staticcall(
        gas(),
        target,
        combined,
        combinedSize,
        mload(0x40),
        0
      )
    }
  }
}