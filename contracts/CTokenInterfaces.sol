// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

contract CTokenStorage {
    // Re-entrancy Attack을 방지하기 위해 있는 플래그
    bool internal _notEntered;

    string public name;
    string public symbol;

    // EIP-20 규격의 토큰을 위한 기본 단위 decimal을 여기에 저장함
    uint8 public decimals;

    // 최대로 대출 가능한 비율, 블록당 0.0005%가 가능한 것으로 디폴트로 지정
    uint internal constant borrowRatemaxMantissa = 0.0005e16;

    // 이게 뭐지?
    uint internal constant reserveFactorMaxMantissa = 1e18;

    // 현재 컨트랙트의 소유자의 주소를 저장
    address payable public admin;
    
    // 해당 컨트랙트를 양도받을 대기중인 admin에 대한 주소
    address payable public pendingAdmin;

    // ControllerInterface public comptroller;

    // InterestRateModel public interestRateModel;

    // 초기 환율을 여기서 지정함
    uint internal initialExchangeRateMantissa;

    // 현재 예비 토큰들이 가지고 있는 이자율
    uint public reserveFactorMantissa;

    // 마지막으로 이자율을 갱신했던 블록의 번호
    uint public accrualBlockNumber;

    // 시장이 열린 이후 총 이자율에 대한 누계치
    uint public borrowIndex;

    // 해당 마켓에서부터 빌려간 토큰양의 합산
    uint public totalBorrows;

    // 마켓에서부터 예비로 비축해둔 토큰의 전체 합산
    uint public totalReserves;

    // 현재 순환중인 공급된 전체 토큰의 양
    uint public totalSupply;

    // 각 계정에 소지중인 토큰의 개수를 매핑하는 자료구조
    mapping (address => uint) internal accountTokens;

    // transfer이 허용된 주소 간의 주고 받을 수 있는 토큰의 양을 기록하는 자료구조
    mapping (address => mapping (address => uint)) internal transferAllowances;

    // 빌려간 토큰 상태를 기록하기 위한 스냅샷 자료구조
    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }

    // 계정마다 어느정도의 대출량을 가졌는지, Snapshot 정보를 통해 유지하면서 정보를 유지
    // 스냅샷으로 정보를 유지하는 이유는 이전에 구해졌던 대출량을 통한 환율, 이자율 등에 대한 계산에 필요하기 때문
    mapping(address => BorrowSnapshot) internal accountBorrows;

    // 청산을 수행할 시에 사용될 청산 비율 공유값
    uint public constant protocolSeizeShareMantissa = 2.8e16;
}

abstract contract CTokenInterface is CTokenStorage {
    bool public constant isCToken = true;

    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
}