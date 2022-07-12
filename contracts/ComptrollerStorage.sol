// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    address public admin;
    address public pendingAdmin;

    // 무조건 예약용 슬롯을 하나 만들어둠
    // 이후에 구현부가 바뀌어야 하는 경우에 활용하는 케이스
    address public comptrollerImplementation;
    address public pendingComptrollerImplementation;
}

// 여기서는 사용자의 마켓에 대한 주요 정보들이 담김
contract ComptrollerV1Storage is UnitrollerAdminStorage {
    PriceOracle public oracle;

    // 대출을 청산하는 과정에서 최대로 갚아야 하는 값을 계산하기 위한 Multiplier 역할
    uint public closeFactorMantissa;

    // 해당 마켓에서 청산 시에 청산인이 받게 되는 담보에 대한 비율의 계산 상수
    uint public liquidationIncentiveMantissa;

    // 계정마다 가질 수 있는 최대 토큰 마켓의 수
    uint public maxAssets;

    // 계정이 갖는 토큰 마켓의 리스트
    mapping(address => CToken[]) public accountAssets;
}

// 마켓에 대한 상세 정보에 대한 스토리지
contract ComptrollerV2Storage is ComptrollerV1Storage {
    // 각 마켓이 가져야 하는 상태 정보를 나타내는 구조체
    struct Market {
        // 해당 마켓이 활성화되어 있는가 여부
        bool isListed;

        // 해당 마켓에서 사용할 대출자들이 맡겨야 하는 담보에 대한 계산 비율 승수
        uint collateralFactorMantissa;

        // 해당 마켓에서 계정이 멤버쉽을 가지는지 회원 여부를 확인
        mapping(address => bool) accountMembership;

        // 해당 마켓이 COMP를 수신받을 수 있는지에 대한 여부
        bool isComped;
    }

    // 각 마켓들의 주소에 대한 마켓 구조체 매핑 자료구조
    mapping(address => Market) public markets;

    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;

    // 왜 굳이 이 두개만 mapping으로 선언한거지?
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;
}

// 여기서는 전역적인 정보들이 담김, 전체 마켓들이나 아니면 해당 마켓에서의 compSpeeds라던가
// 혹은 SupplyState라던가 하는 것들을 여기서 취급
contract ComptrollerV3Storage is ComptrollerV2Storage {
    // Compound 프로토콜에 기반한 마켓의 상태 정보를 나타내는 구조체
    struct CompMarketState {
        uint224 index;
        uint32 block;
    }

    // 모든 마켓들에 대한 정보
    CToken[] public allMarkets;

    uint public compRate;
    mapping(address => uint) public compSpeeds;
    mapping(address => CompMarketState) public compSupplyState;
    mapping(address => CompMarketState) public compBorrowState;
    mapping(address => mapping(address => uint)) public compSupplierIndex;
    mapping(address => mapping(address => uint)) public compBorrowerIndex;
    mapping(address => uint) public compAccrued;
}

// 여기서는 이제 대출자에 대해 관리하기 위한 Guardian 정보
contract ComptrollerV4Storage is ComptrollerV3Storage {
    address public borrowCapGuardian;
    mapping(address => uint) public borrowCaps;
}

contract ComptrollerV5Storage is ComptrollerV4Storage {
    mapping(address => uint) public compContributorSpeeds;
    mapping(address => uint) public lasetContributorBlock;
}

contract ComptrollerV6Storage is ComptrollerV5Storage {
    mapping(address => uint) public compBorrowSpeeds;
    mapping(address => uint) public compSupplySpeeds;
}

contract ComptrollerV7Storage is ComptrollerV6Storage {
    bool public proposal65FixExecuted;

    // 각 계정이 얼마만큼의 Comp 토큰을 가지는지 등에 대해 관리
    mapping(address => uint) public compReceivable;
}