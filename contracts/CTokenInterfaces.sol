// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";
import "./InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";
import "./ErrorReporter.sol";

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

    // 새로 이자율을 갱신했을 때 발생하는 이벤트
    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);

    // mint를 수행했을 때 발생하는 이벤트
    event Mint(address minter, uint mintAmount, uint mintTokens);

    // redeem으로 상환을 수행했을 때 발생하는 이벤트
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
    event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
    event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);
    event LiquidateBorrow(address liquidator, address borrower, uint repayAmount, address cTokenCollateral, uint seizeTokens);
    

    // admin events
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address, oldAdmin, address newAdmin);
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);
    event NewMarketInterestRateModel(InterestRateModel oldInterestRateModel, InterestRateModel newInterestRateModel);
    event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);
    event ReservesAdded(address benefactor, uint addAmount, uint newTotalReserves);
    event ReservesReduced(address admin, uint reduceAmount, uint newTotalReserves);
    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed owner, address indexed spender, uint amount);

    function transfer(address dst, uint amount) virtual external returns (bool);
    function transferFrom(address src, address dst, uint amount) virtual external returns (bool);
    function approve(address spender, uint amount) virtual external returns (bool);
    function allowance(address owner, address spender) virtual external view returns (uint);
    function balanceOf(address owner) virtual external view returns (uint);
    function balanceOfUnderlying(address owner) virtual external returns (uint);
    function getAccountSnapshot(address account) virtual external view returns (uint, uint, uint, uint);
    function borrowRatePerBlock() virtual external view returns (uint);
    function supplyRatePerBlock() virtual external view returns (uint);
    function totalBorrowsCurrent() virtual external returns (uint);
    function borrowBalanceCurrent(address account) virtual external returns (uint);
    function borrowBalanceStored(address account) virtual external view returns (uint);
    function exchangeRateCurrent() virtual external returns (uint);
    function exchangeRateStored() virtual external view returns (uint);
    function getCash() virtual external view returns (uint);
    function accrueInterest() virtual external returns (uint);
    function seize(address liquidator, address borrower, uint seizeTokens) virtual external returns (uint);


    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) virtual external returns (uint);
    function _acceptAdmin() virtual external returns (uint);
    function _setComptroller(ComptrollerInterface newComptroller) virtual external returns (uint);
    function _setReserveFactor(uint newReserveFactorMantissa) virtual external returns (uint);
    function _reduceReserves(uint reduceAmount) virtual external returns (uint);
    function _setInterestRateModel(InterestRateModel newInterestRateModel) virtual external returns (uint);
}

contract CErc20Storage {
    address public underlying;
}

abstract contract CErc20Interface is CErc20Storage {
    /*** User Interface ***/

    function mint(uint mintAmount) virtual external returns (uint);
    function redeem(uint redeemTokens) virtual external returns (uint);
    function redeemUnderlying(uint redeemAmount) virtual external returns (uint);
    function borrow(uint borrowAmount) virtual external returns (uint);
    function repayBorrow(uint repayAmount) virtual external returns (uint);
    function repayBorrowBehalf(address borrower, uint repayAmount) virtual external returns (uint);
    function liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) virtual external returns (uint);
    function sweepToken(EIP20NonStandardInterface token) virtual external;


    /*** Admin Functions ***/
    function _addReserves(uint addAmount) virtual external returns (uint);
}

contract CDelegationStorage {
    address public implementation;
}

abstract contract CDelegatorInterface is CDelegationStorage {
    /**
     * @notice Emitted when implementation is changed
     */
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData) virtual external;
}

abstract contract CDelegateInterface is CDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) virtual external;

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() virtual external;
}
