// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

enum SaleSide {
  BUY,
  SELL
}

enum SaleKind {
  FIXED_PRICE,
  AUCTION
}

// 수수료 관련 부분, howToCall(opensea는 call만 사용) 제거
struct Order {
  address exchange; // 주문이 사용되는 거래소 주
  address maker;    // 주문 생성자 주소
  address taker;    // 거래 상대방 주소, Order 생성 순간에는 값이 없을 수도 있음 -> null
  SaleSide saleSide;
  SaleKind saleKind;
  address target;   // targt NFT 컨트랙트 주소
  address paymentToken; // 지불 토큰 주소
  bytes calldata_;
  bytes replacementPattern;
  address staticTarget;
  bytes staticExtra;
  uint256 basePrice;
  uint256 endPrice;
  uint256 listingTime;
  uint256 expirationTime;
  uint256 salt;
}