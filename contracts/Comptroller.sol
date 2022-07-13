// SPDX-License-Identifier: BSD-3-Clause

import "./CToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/Comp.sol";

contract Comptroller is ComptrollerInterface, ComptrollerErrorReporter, ExponentialNoError {
    event MarketListed(CToken cToken);
    event MarketEntered(CToken cToken, address account);
    event MarketExited(CToken cToken, address account);
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);
    event NewCollateralFactor(CToken cToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);
    event ActionPaused(string action, bool pauseState);
    event ActionPaused(CToken cToken, string action, bool pauseState);
    event CompBorrowSpeedUpdated(CToken indexed cToken, uint newSpeed);
    event CompSupplySpeedUpdated(CToken indexed cToken, uint newSpeed);
    event ContributorCompSpeedUpdated(address indexed contributor, uint newSpeed);
    event DistributedSupplierComp(CToken indexed cToken, address indexed supplier, uint compDelta, uint compSupplyIndex);
    event DistributedBorrowerComp(CToken indexed cToken, address indexed borrower, uint compDelta, uint compBorrowIndex);
    event NewBorrowCap(CToken indexed cToken, uint newBorrowCap);
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);
    event CompGranted(address recipient, uint amount);
    event CompAccruedAdjusted(address indexed user, uint oldCompAccrued, uint newCompAccrued);
    event CompReceivableUpdated(address indexed user, uint oldCompReceivable, uint newCompReceivable);

    uint224 public constant compInitialIndex = 1e36;
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        // admin은 ComptrollerStorage에 작성되어 있는 현재 Comptroller 컨트랙트의 소유주를 가르키는 변수
        admin = msg.sender;
    }

    function getAssetsIn(address account) external view returns (CToken[] memory) {
        CToken[] memory assetsIn = accountAssets[account];
        return assetsIn;
    }

    // 각 markets들은 accountMembership이라고 해서 자기 자신 마켓이 보유한 계정들의 멤버쉽 여부 리스트가 있음
    // Storage에 저장되어 있기 때문에 ComptrollerStorage.sol을 참고하면 됨
    function checkMembership(address account, CToken cToken) external view returns (bool) {
        return markets[address(cToken)].accountMembership[account];
    }

    function enterMarkets(address[] memory cTokens) override public returns (uint[] memory) {
        uint len = cTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            CToken cToken = CToken(cTokens[i]);
            results[i] = uint(addToMarketInternal(cToken, msg.sender));
        }
        return results;
    }

    function addToMarketInternal(CToken cToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(cToken)];

        if (!marketToJoin.isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // 이미 해당 마켓에 들어온 상태
        if (marketToJoin.accountMembership[borrower] == true) {
            return Error.NO_ERROR;
        }

        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);
        return Error.NO_ERROR;
    }

    function exitMarket(address cTokenAddress) override external returns (uint) {
        CToken cToken = CToken(cTokenAddress);
        (uint oErr, uint tokensHeld, uint amountOwed, ) = cToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed");

        // 현재 해당 마켓에서 보유한 토큰량이 0이 아닐 경우에는 에러를 발생시킴
        // 아마 보유자가 실수로 마켓에서 나가는 선택을 했을 경우 토큰을 보유한 상태라면
        // 의도치않게 불이익을 받을 수 있기 때문에 이렇게 구현한듯
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        uint allowed = redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(cToken)];

        // 만약 이미 멤버쉽이 없는 상태면 이미 퇴장한 것이기 때문에 그냥 일반 종료를 수행
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        delete marketToExit.accountMembership[msg.sender];

        CToken[] memory userAssetList = accountAssets[msg.sender];

        uint len = userAssetList.length;
        uint assetIndex = len;

        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == cToken) {
                assetIndex = i;
                break;
            }
        }

        // 굳이 이렇게 Asset의 위치를 찾는 이유는, 일방적으로 delete를 하게 되면 해당 위치의 Null이 생기면서
        // 이후에 잘못된 처리를 할 가능성이 생기기 때문
        assert(assetIndex < len);

        // 그냥 마지막에 있는 멤버를 해당 삭제 에셋 멤버 위치로 복사해서 삭제 에셋을 리스트에서 제거하고
        // 마지막에 중복으로 저장된 멤버를 pop하는 것으로 없애는 방식을 선택
        CToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(cToken, msg.sender);
        return uint(Error.NO_ERROR);
    }

    // Allowed 계열 함수는 해당 CToken에 대한 마켓이 공개되어 있는지에 대한 여부
    // 그리고 해당 Operation에 대해서 Paused되어 있는지 아닌지에 대한 여부를 확인하며
    // Index 값을 업데이트 해주는 역할을 수행함
    function mintAllowed(address cToken, address minter, uint mintAmount) override external returns (uint) {
        require(!mintGuardianPaused[cToken], "mint is paused");

        minter;
        mintAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, minter);

        return uint(Error.NO_ERROR);
    }

    function mintVerify(address cToken, address minter, uint actualMintAmount, uint mintTokens) override external {
        cToken;
        minter;
        actualMintAmount;
        mintTokens;

        if (false) {
            maxAssets = maxAssets;
        }
    }

    function redeemAllowed(address cToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(cToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address cToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 이건 해당 마켓에 대한 권한이 없을 경우
        if (!markets[cToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        // 해당 함수는 대출량이 담보량보다 많은지를 확인하는 함수
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, CToken(cToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }
        return uint(Error.NO_ERROR);
    }

    function redeemVerify(address cToken, address redeemer, uint redeemAmount, uint redeemTokens) override external  {
        cToken;
        redeemer;

        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    function borrowAllowed(address cToken, address borrower, uint borrowAmount) override external returns (uint) {
        require(!borrowGuardianPaused[cToken], "borrow is paused");

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[cToken].accountMembership[borrower]) {
            // 만약 대출자가 해당 마켓에 소속되어 있지 않더라도
            // sender가 cToken일 경우에는 해당 마켓에 가입할 수 있게 해준 이후 수행
            require(msg.sender == cToken, "sender must be cToken");

            Error err = addToMarketInternal(CToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // 정상적으로 해당 마켓에 대한 멤버쉽을 취득했는지 확인
            assert(markets[cToken].accountMembership[borrower]);
        }

        // 해당 마켓 토큰에 대한 가치가 0일 경우에는 뭔가 에러가 있는 경우임
        if (oracle.getUnderlyingPrice(CToken(cToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        // borrowCaps는 해당 토큰에서 최대로 대출이 가능한 한도를 명시하는 부분
        // 만일 0일 경우에는 제한이 없음을 의미함
        uint borrowCap = borrowCaps[cToken];

        if (borrowCap != 0) {
            // 0이 아닐 경우에는 한도가 존재함
            uint totalBorrows = CToken(cToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);

            // 해당 require 구문에 걸리면 현재 대출하려는 한도가 토큰에 명시된 한도를 넘기는 경우임
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, CToken(cToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    function borrowVerify(address cToken, address borrower, uint borrowAmount) override external {
        cToken;
        borrower;
        borrowAmount;

        if (false) {
            maxAssets = maxAssets;
        }
    }

    // 이건 대출한 토큰을 갚을 수 있는지에 대한 여부
    // 확인해야 할만한건 해당 마켓이 오픈되어 있는지, 그리고 해당 마켓에서부터 대출한게 존재하는지
    // 그리고 Oracle 가격이 정상인지 등에 대한 여부를 확인해야함
    function repayBorrowAllowed(address cToken, address payer, address borrower, uint repayAmount) override external returns (uint) {
        payer;
        borrower;
        repayAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 왜이렇게 코드가 짧은지 조금 이해가 안됨
        // 상환하는 코드는 해당 컨트랙트 서비스에서 손실을 줄만한 오퍼레이션이 아니라서 그런가?
        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    function repayBorrowVerify(address cToken, address payer, address borrower, uint actualRepayAmount, uint borrowerIndex) override external {
        cToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        if (false) {
            maxAssets = maxAssets;
        }
    }

    function liquidateBorrowAllowed(address cTokenBorrowed, address cTokenCollateral,
                                    address liquidator, address borrower,
                                    uint repayAmount) override external returns (uint) {
        liquidator;

        if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // 해당 대출 토큰이 갖고 있는 전체 대출 토큰량
        uint borrowBalance = CToken(cTokenBorrowed).borrowBalanceStored(borrower);

        if (isDeprecated(CToken(cTokenBorrowed))) {
            // 전체 대출량 이상으로 갚으려고 하는 경우엔 하지 못하도록 차단
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        }
        else {
            // 이 경우는 해당 토큰이 Deprecated 되지 않은 경우
            (Error err, , uint shortfall) =  getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // shortfall은 0이 되는 경우에 대출량, 담보량이 동일한 경우가 됨
            // 이 경우에는 굳이 무리해서 청산을 할 이유가 없기 때문에 에러를 발생시킴
            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            // 청산 값을 계산하기 위한 Multiplier로 closeFactorMantissa가 Storage에 있음
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    function liquidateBorrowVerify(address cTokenBorrowed, address cTokenCollateral,
                                    address liquidator, address borrower,
                                    uint actualRepayAmount, uint seizeTokens) override external {
        cTokenBorrowed;
        cTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        if (false) {
            maxAssets = maxAssets;
        }
    }

    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external returns (uint) {
        
        require(!seizeGuardianPaused, "seize is paused");
        seizeTokens;

        if (!markets[cTokenCollateral].isListed || !markets[cTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (CToken(cTokenCollateral).comptroller() != cToken(cTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        updateCompSupplyIndex(cTokenCollateral);
        distributeSupplierComp(cTokenCollateral, borrower);
        distributeSupplierComp(cTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    function seizeVerify(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external {
        // Shh - currently unused
        cTokenCollateral;
        cTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    function transferAllowed(address cToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(cToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, src);
        distributeSupplierComp(cToken, dst);

        return uint(Error.NO_ERROR);
    }

    function transferVerify(address cToken, address src, address dst, uint transferTokens) override external {
        // Shh - currently unused
        cToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }


    // 굳이 각 계정들이 가지는 Liquidity 정보를 왜 Storage가 아닌 이 컨트랙트에 저장하는가?

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint cTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);
        return (uint(err), liquidity, shortfall);
    }

    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address cTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(cTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    function getHypotheticalAccountLiquidityInternal(
        address account,
        CToken cTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        CToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            CToken asset = assets[i];

            // Read the balances and exchange rate from the cToken
            (oErr, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});     // 담보
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});     // 교환 비율

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);        // 표준 Oracle 가치
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            // 담보비율 * 환율 * 오라클 가격
            // 담보 비율 가치를 ether로 환산
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * cTokenBalance
            // sumCollateral : 전체 담보량
            // tokensToDenom : 담보 비율
            // cTokenBalance : 현재 계정의 cToken의 양
            // 현재 계정이 보유한 cToken의 양에서 담보 비율을 곱해 토큰 대비 담보량을 계산하여 전체 담보량에 더함
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.cTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            // 대출해간 토큰에 오라클 가격을 곱해 누적함
            // 대출한 토큰의 가치를 누적하는 로직
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with cTokenModify
            if (asset == cTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                // 여기선 상환한 토큰의 가치를 더함
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                // 여기서는 빌려간 양 만큼의 오라클 가격을 더함
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
            // 즉 전체 에셋을 돌면서 사용자와 트랜잭션으로 교환이 이루어진 전체 유동량을 누적하여 계산함
        }

        // These are safe, as the underflow condition is checked first
        // 전체 담보량과 전체 대출한 토큰의 가치의 차이를 리턴함
        // 대출량이 담보량보다 큰지 작은지를 판단하는 함수
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    function liquidateCalculateSeizeTokens(address cTokenBorrowed, address cTokenCollateral, uint actualRepayAmount) override external view returns (uint, uint) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(CToken(cTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(CToken(cTokenCollateral));

        // 둘 중 하나라도 가격이 0이라면 에러가 있는 상황
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        uint exchangeRateMantissa = CToken(cTokenCollateral).exchangeRateStored();
        uint seizeTokens;

        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));

        ratio = div_(numerator, denominator);
        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    // Admin Functions
    function _setPriceOracle() {

    }

    function _setCloseFactor() {

    }

    function _setCollateralFactor() {

    }

    function _setLiquidationIncentive() {

    }

    function _supportMarket() {

    }

    function _addMarketInternal() {

    }

    function _initializeMarket() {

    }

    function _setMarketBorrowCaps() {

    }

    function _setBorrowCapGuardian() {

    }

    function _setPauseGuardian() {

    }

    function _setMintPaused() {

    }

    function _setBorrowPaused() {

    }

    function _setTransferPaused() {

    }

    function _setSeizePaused() {

    }

    function _become() {

    }

    function fixBadAccruals() {

    }

    function adminOrInitializing() {

    }

    function setCompSpeedInternal() {

    }

    function updateCompSupplyIndex() {

    }

    function updateCompBorrowIndex() {

    }

    function distributeSupplierComp() {

    }

    function distributeBorrowerComp() {

    }

    function updateContributorRewards() {

    }

    function claimComp() {

    }

    function claimComp() {

    }

    function claimComp() {

    }

    function grantCompInternal() {

    }

    function _grantComp() {

    }

    function _setCompSpeeds() {

    }

    function _setContributorCompSpeed() {

    }

    function getAllMarkets() {

    }

    function isDeprecated() {

    }

    function getBlockNumber() {

    }

    function getCompAddress() {

    }
}