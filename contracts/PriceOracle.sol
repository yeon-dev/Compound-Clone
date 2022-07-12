// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";

abstract contract PriceOracle {
    bool public constant isPriceOracle = true;

    // 가상 컨트랙트로 구현된 이유는 해당 함수가 토큰의 종류마다 달라지기 때문
    function getUnderlyingPrice(CToken cToken) virtual external view returns (uint);
}