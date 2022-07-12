// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";
import "./CTokenInterfaces.sol";
import "./ErrorReporter.sol";
import "./EIP20Interface.sol";
import "./InterestRateModel.sol";
import "./ExponentialNoError.sol";

// 내부적으로 가상 컨트랙트인 CTokenInterface를 구현해야함
// 나머지 ExponentialNoError와 TokenErrorReporter는 그냥 에러를 사용하기 위해 상속받는 것이기 때문에
// 크게 신경쓰지 않아도 됨
abstract contract CToken is CTokenInterface, ExponentialNoError, TokenErrorReporter {

    // initialize 함수를 통해서 해당 CToken이 연관된 Comptroller를 지정하고
    // 이자율 모델을 설정해 해당 토큰이 활용할 이자율 알고리즘을 계산함
    // decimals의 경우 해당 토큰이 기본적으로 어떤 단위를 가지는지 그 토큰의 기초 가치를 설정함
    function initialize(ComptrollerInterface comptroller_,
                        InterestRateModel interestRateModel_,
                        uint initialExchangeRateMantissa_,
                        string memory name_,
                        string memory symbol_,
                        uint8 decimals_) public {
        // name_이랑 symbol_에 memory를 붙이는 이유는 임시로 저장하기만 하면 되는 스트링 정보이기 때문
        // 어차피 내부적으로 name이랑 symbol이라는 storage 영역에 따로 저장함

        // 이 initialize 함수의 경우 외부에서 delegate call로 불리기 때문에 admin이 이미 사전에 설정됨
        require(msg.sender == admin, "only admin may initialize the market");
        // 이미 초기화가 되었다면 더이상 호출이 불가능함, 1번만 호출이 가능함
        require(accrualBlockNumber == 0 && borrowIndex == 0, "market may only be initialized once");

        // 초기 이자율 설정
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
        // 초기 이자율이 0이거나 그보다 작으면 정상적인 이자율이 아니기 때문에 에러 발생
        require(initialExchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");

        uint err = _setComptroller(comptroller_);
        require(err == NO_ERROR, "setting comptroller failed");

        // 현재 블록 번호를 구함
        accrualBlockNumber = getBlockNumber();
        borrowIndex = mantissaOne;

        // 사용할 이자율 계산 모델을 지정함
        err = _setInterestRateModelFresh(interestRateModel_);
        require(err == NO_ERROR, "setting interest rate model failed");

        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // Re-entrancy Attack을 방지하기 위한 부분
        _notEntered = true;
    }

    // spender은 이 transfer 명령을 수행하는 주체가 되는 실행자
    function transferTokens(address spender, address src, address dst, uint tokens) internal returns (uint) {
        if (src == dst) {
            // source와 destination은 동일할 수 없음
            revert TransferNotAllowed();
        }

        uint startingAllowance = 0;
        if (spender == src) {
            startingAllowance = type(uint).max;
        } else {
            // 여기서 src -> spender로 지정하는 이유는 잘은 모르겠으나, 애초에 src가 보유한
            // 전송 가능한 토큰의 양의 경우 spender에게 전송이 가능한 양과 dst에게 전송이 가능한 양은
            // 동일할 것이기 때문에 이런식으로 작성한 것으로 보임
            startingAllowance = transferAllowances[src][spender];
        }

        uint allowanceNew = startingAllowance - tokens;
        uint srcTokensNew = accountTokens[src] - tokens;
        uint dstTokensNew = accountTokens[dst] + tokens;

        // 새롭게 계정 보유 토큰량 정보를 갱신
        accountTokens[src] = srcTokensNew;
        accountTokens[dst] = dstTokensNew;

        // type(uint).max인 경우는 spender와 src가 같을 경우
        if (startingAllowance != type(uint).max) {
            // 이 경우는 같지 않을 경우에 해당함
            // 애초에 자기 자신에게 전송하는 경우에는 보유한 토큰만큼은 무제한으로 보낼 수 있기 때문
            transferAllowances[src][spender] = allowanceNew;
        }

        emit Transfer(src, dst, tokens);
        return NO_ERROR;
    }

    // nonReentrant modifier 덕분에 해당 함수에서는 재진입 공격이 불가능함
    function transfer(address dst, uint256 amount) override external nonReentrant returns (bool) {
        // 여기서 spender와 src가 동일한 전송자로 수행
        return transferTokens(msg.sender, msg.sender, dst, amount) == NO_ERROR;
    }

    function transferFrom(address src, address dst, uint256 amount) override external nonReentrant returns (bool) {
        return transferTokens(msg.sender, src, dst, amount) == NO_ERROR;
    }

    function approve(address spender, uint256 amount) override external returns (bool) {
        address src = msg.sender;
        // 여기서 src -> spender로 amount만큼을 지정함, 왜 굳이 spender인지는 잘 모르겠음
        transferAllowances[src][spender] = amount;
        emit Approval(src, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) override external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    function balanceOf(address owner) override external view returns (uint256) {
        return accountTokens[owner];
    }

    function balanceOfUnderlying(address owner) override external returns (uint) {
        // Underlying의 의미 자체를 아직 완전히 이해하진 않았지만
        // 코드를 살펴보니 환율을 통해 실제 토큰의 가치 기반 사용자 보유량을 반환하는 함수로 보임
        Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    function getAccountSnapshot(address account) override external view returns (uint, uint, uint, uint) {
        return (
            NO_ERROR,
            accountTokens[account],
            borrowBalanceStoredInternal(account),
            exchangeRateStoredInternal()
        );
    }

    function getBlockNumber() virtual internal view returns (uint) {
        return block.number;
    }

    function borrowRatePerBlock() {

    }

    function supplyRatePerBlock() {

    }

    function totalBorrowsCurrent() {

    }

    function borrowBalanceCurrent(address account) override external nonReentrant returns (uint) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    function borrowBalanceStored(address account) override public view returns (uint) {
        return borrowBalanceStoredInternal(account);
    }

    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        uint principalTimesIndex = borrowSnapshot.principal * borrowIndex;
        return principalTimesIndex / borrowSnapshot.interestIndex;
    }

    // 굳이 nonReentrant가 붙은 이유?
    // 사실 nonReentrant가 붙지 않아도 크게 직접적으로 해당 함수 안에서 위협이 발생할 코드는 딱히 없음
    // 다만 해당 함수가 사용되는 다른 함수들의 위협을 생각해서 이렇게 작성한듯
    function exchangeRateCurrent() override public nonReentrant returns (uint) {
        accrueInterest();
        return exchangeRateStored();
    }

    function exchangeRateStored() override public view returns (uint) {
        return exchangeRateStoredInternal();
    }

    // 해당 함수가 virtual인 이유는 CToken을 내려받는 자식 토큰 컨트랙트마다 환율 계산 공식이 달라질 수도 있기 때문
    function exchangeRateStoredInternal() virtual internal view returns (uint) {
        // totalSupply는 이미 Storage에 저장되어 있는 전체 토큰 공급량 (Circulation 기반)
        uint _totalSupply = totalSupply;

        if (_totalSupply == 0) {
            // 공급량이 아직 아무것도 없으면 초기 환율을 돌려주면 됨
            return initialExchangeRateMantissa;
        } else {
            // 컨트랙트가 가진 전체 캐쉬 잔액
            // getCashPrior() 함수는 실제 구현부가 CToken을 내려받는 함수마다 달라짐
            uint totalCash = getCashPrior();
            // 예비 토큰을 제외한 전체 토큰량
            uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            uint exchangeRate = cashPlusBorrowsMinusReserves * expScale / _totalSupply;

            return exchangeRate;
        }
    }

    function getCash() override external view returns (uint) {
        return getCashPrior();
    }

    // 실제로 계산식이 필요한 영역은 컨트랙트에 따라 해당 계산식이 바뀔 수 있기 때문에 virtual로 선언됨
    function accrueInterest() virtual override public returns (uint) {
        // 현재 블록과 마지막으로 이자율을 갱신한 블록을 로컬 변수에 저장
        uint currentBlockNumber = getBlockNumber();
        uint accrualBlockNumberPrior = accrualBlockNumber;

        // 마지막 갱신일자와 현재 블록이 동일하면 아무런 처리를 수행할 필요 없음
        // 여기서는 Re entrancy attack이 발생하지 않음
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return NO_ERROR;
        }

        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        // 이자율 계산 모델을 이용해서 getBorrowsRate 함수를 통해 여기에 맞는 이자율 모델을 활용함
        // 상속관계가 아니라 의존 관계
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        // 지금까지 마지막 이자율 업데이트 이후에 생성되었던 블록들의 간격을 계산
        uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        // 대출 이자율과 전체 대출 토큰량을 곱해서 대출 토큰량의 현 시점 이자율 포함 가치를 계산
        Exp memory simpleInterestFactor = mul_(Exp({mantissa: borrowRateMantissa}), blockDelta);
        uint interestAccumulated = mul_ScalarTruncate(simpleInterestFactor, borrowsPrior);

        // 이 둘을 더하는 것으로 업데이트되어야 하는 대출량의 값을 구함
        uint totalBorrowsNew = interestAccumulated + borrowsPrior;
        uint totalReservesNew = mul_ScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        uint borrowIndexNew = mul_ScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
        return NO_ERROR;
    }

    function mintInternal(uint mintAmount) internal nonReentrant {
        accrueInterest();
        mintFresh(msg.sender, mintAmount);
    }

    function mintFresh(address minter, uint mintAmount) internal {
        // Allowed 코드 필요

        if (accrualBlockNumber != getBlockNumber()) {
            revert MintFreshnessCheck();
        }

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
        // 현재 mint되는 토큰에 대한 총량을 계산함
        // doTransferIn의 경우 CErc20과 CEther의 구현부가 서로 다름
        // CEther은 amount만큼을 되돌리기 때문에 그냥 mintAmount가 actualMintAmount가 됨
        // 반면에 CErc20의 경우 transferFrom을 직접 수행함
        // 근데 이렇게 되면 실제로 보유한 토큰량에 변화가 생길텐데 상관이 없나 생각중
        uint actualMintAmount = doTransferIn(minter, mintAmount);

        // 환율로 실제 mint되는 양을 나눔으로 이 mint되는 양이 토큰으로는 얼마만큼인지를 계산함
        uint mintTokens = div_(actualMintAmount, exchangeRate);

        totalSupply = totalSupply + mintTokens;
        accountTokens[minter] = accountTokens[minter] + mintTokens;

        emit Mint(minter, actualMintAmount, mintTokens);
        emit Transfer(address(this), minter, mintTokens);
    }

    function redeemInternal(uint redeemTokens) internal nonReentrant {
        // accrueInterest()가 실행이 되는 이유는 이러한 상환, 대출 및 청산 등의 함수를 실행하기에 앞서
        // 이자율을 업데이트 할 필요가 있기 때문
        accrueInterest();
        redeemFresh(payable(msg.sender), redeemTokens, 0);
    }

    // 기능상 redeemInternal() 함수와 반대되는 방식으로 상환
    function redeemUnderlyingInternal(uint redeemAmount) internal nonReentrant {
        accrueInterest();
        redeemFresh(payable(msg.sender), 0, redeemAmount);
    }

    // redeemTokensIn의 경우 하위 컨트랙트에 상환할 cToken의 수
    // redeemAmountIn의 경우 상환하는 cToken으로부터 계산할 수 있는 Amount
    function redeemFresh(address payable redeemer, uint redeemTokensIn, uint redeemAmountIn) internal {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "one of redeemTokensIn or redeemAmountIn must be zero");

        // 현재 환율을 계산
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});

        uint redeemTokens;
        uint redeemAmount;

        // 이 경우 하위 컨트랙트에 cToken을 상환하려는 경우
        if (redeemTokensIn > 0) {
            redeemTokens = redeemTokensIn;
            redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokensIn);
        } else {
            // 이게 아닌 경우에는 redeemAmountIn이 제공된 경우로, 토큰이 아니라 Amount가 기준이 된 경우를 의미
            redeemTokens = div_(redeemAmountIn, exchangeRate);
            redeemAmount = redeemAmountIn;
        }

        // allowed check 필요, from comptroller
        if (accrualBlockNumber != getBlockNumber()) {
            revert RedeemFreshnessCheck();
        }

        // 현재 보유한 캐쉬 잔액이 상환하고자 하는 토큰의 가치보다 적을 경우엔 상환이 불가능
        if (getCashPrior() < redeemAmount) {
            revert RedeemTransferOutNotPossible();
        }

        totalSupply = totalSupply - redeemTokens;
        accountTokens[redeemer] = accountTokens[redeemer] - redeemTokens;

        // 실제 가치를 계산해서 Ether로 전달
        doTransferOut(redeemer, redeemAmount);

        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens);

        // comptroller의 redeemVerify가 필요
    }

    function borrowInternal() {

    }

    function borrowFresh() {

    }

    function repayBorrowInternal() {

    }

    function repayBorrowBehalfInternal() {

    }

    function repayBorrowFresh() {

    }

    function liquidateBorrowInternal() {

    }

    function liquidateBorrowFresh() {

    }

    function seize() {

    }

    function seizeInternal() {

    }

    // Admin Functions

    function _setPendingAdmin() {

    }

    function _acceptAdmin() {

    }

    function _setComptroller(ComptrollerInterface newComptroller) override public returns (uint) {
        if (msg.sender != admin) {
            // 오직 관리자만이 해당 함수로 Comptroller를 지정할 수 있음
            revert SetComptrollerOwnerCheck();
        }

        ComptrollerInterface oldComptroller = comptroller;
        require(newComptroller.isComptroller(), "marker method returned false");

        comptroller = newComptroller;
        emit NewComptroller(oldComptroller, newComptroller);

        return NO_ERROR;
    }

    function _setReserveFactor() {

    }

    function _setReserveFactorFresh() {

    }

    function _addReservesInternal() {

    }

    function _reduceReserves() {

    }

    function _reduceReservesFresh() {

    }

    function _setInterestRateModel() {

    }

    function _setInterestRateModelFresh(InterestRateModel newInterestRateModel) internal returns (uint) {
        if (msg.sender != admin) {
            revert SetInterestRateModelOwnerCheck();
        }

        // _setInterestRateModelFresh()는 현재 initialize() 함수에서 호출되었을 때의 블록과 동일한
        // 블록에서만 실행할 수 있음
        if (accrualBlockNumber != getBlockNumber()) {
            revert SetInterestRateModelFreshCheck();
        }

        InterestRateModel oldInterestRateModel = interestRateModel;
        require(newInterestRateModel.isInterestRateModel(), "marker method returned false");

        interestRateModel = newInterestRateModel;

        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);
        return NO_ERROR;
    }

    function getCashPrior() virtual internal view returns (uint);
    function doTransferIn(address from, uint amount) virtual internal returns (uint);
    function doTransferOut(address payable to, uint amount) virtual internal;

    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true;
    }
}