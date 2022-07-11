// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

abstract contract InterestRateModel {
    bool public constant isInterestRateModel = true;

    // 두 함수는 전부 어떤 토큰이냐에 따라 구현부가 달라지기 때문에 virtual 함수로 선언되어 있음
    // 알다시피 대출 이자율을 계산하기 위한 함수
    function getBorrowRate(uint cash, uint borrows, uint reserves) virtual external view returns (uint);

    // 알다시피 공급률에 대해 계산하기 위한 함수
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) virtual external view returns (uint);
}
