// SPDX-License-Identifier: ISC
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../src/contracts/FraxlendPairConstants.sol";
import "../../src/contracts/FraxlendPairDeployer.sol";
import "../../src/contracts/FraxlendPairHelper.sol";
import "../../src/contracts/VariableInterestRate.sol";
import "../../src/contracts/LinearInterestRate.sol";
import "../../src/contracts/FraxlendPair.sol";
import "./Scenarios.sol";

library OracleHelper {
    /// @notice The ```setPrice``` function uses a numerator and denominator value to set a price
    /// using the number of decimals from the oracle itself
    /// @dev Remember the units here, quote per asset i.e. USD per ETH for the ETH/USD oracle
    /// @param _oracle The oracle to mock
    /// @param numerator The numerator of the price
    /// @param denominator The denominator of the price
    /// @param vm The vm from forge
    function setPrice(AggregatorV3Interface _oracle, uint256 numerator, uint256 denominator, Vm vm)
        internal
    {
        vm.mockCall(
            address(_oracle),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(
                uint80(0),
                int256((numerator * 10 ** _oracle.decimals()) / denominator),
                0,
                0,
                uint80(0)
            )
        );
        vm.warp(block.timestamp + 15);
        vm.roll(block.number + 1);
    }
}

contract BasePairTest is FraxlendPairConstants, Scenarios, Test {
    using stdStorage for StdStorage;
    using OracleHelper for AggregatorV3Interface;

    // contracts
    FraxlendPair public pair;
    FraxlendPairDeployer public deployer;
    FraxlendPairHelper public fraxlendPairHelper;
    IERC20 public asset;
    IERC20 public collateral;
    VariableInterestRate public variableRateContract;
    LinearInterestRate public linearRateContract;

    AggregatorV3Interface public oracleDivide;
    AggregatorV3Interface public oracleMultiply;
    uint256 public oracleNormalization;

    struct PairAccounting {
        uint128 totalAssetAmount;
        uint128 totalAssetShares;
        uint128 totalBorrowAmount;
        uint128 totalBorrowShares;
        uint256 totalCollateral;
    }

    PairAccounting public initial;
    PairAccounting public final_;
    PairAccounting public net;

    // Users
    address[] public users = [vm.addr(1), vm.addr(2), vm.addr(3), vm.addr(4), vm.addr(5)];

    // Constants
    address internal constant FRAX_ERC20 = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    address internal constant FPI_ERC20 = 0x5Ca135cB8527d76e932f34B5145575F9d8cbE08E;
    address internal constant FPIS_ERC20 = 0xc2544A32872A91F4A553b404C6950e89De901fdb;
    address internal constant FXS_ERC20 = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address internal constant WETH_ERC20 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant USDC_ERC20 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Admin contracts
    address internal constant CIRCUIT_BREAKER_ADDRESS = 0x46446a6473E0Eb92fc6938f020c328973098c554;
    address internal constant COMPTROLLER_ADDRESS = 0x8D8Cb63BcB8AD89Aa750B9f80Aa8Fa4CfBcC8E0C;
    address internal constant TIME_LOCK_ADDRESS = 0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA;

    // Deployer constants
    uint256 internal constant DEFAULT_MAX_LTV = 75_000; // 75% with 1e5 precision
    uint256 internal constant DEFAULT_LIQ_FEE = 500; // 5% with 1e5 precision

    // Interest Helpers
    uint256 internal constant ONE_PERCENT_ANNUAL_RATE = 14_624_850;

    function takeInitialAccountingSnapshot(FraxlendPair _fraxlendPair) internal {
        (
            uint128 _totalAssetAmount,
            uint128 _totalAssetShares,
            uint128 _totalBorrowAmount,
            uint128 _totalBorrowShares,
            uint256 _totalCollateral
        ) = fraxlendPairHelper.getPairAccounting(address(_fraxlendPair));
        initial.totalAssetAmount = _totalAssetAmount;
        initial.totalAssetShares = _totalAssetShares;
        initial.totalBorrowAmount = _totalBorrowAmount;
        initial.totalBorrowShares = _totalBorrowShares;
        initial.totalCollateral = _totalCollateral;
    }

    function takeFinalAccountingSnapshot(FraxlendPair _fraxlendPair) internal {
        (
            uint128 _totalAssetAmount,
            uint128 _totalAssetShares,
            uint128 _totalBorrowAmount,
            uint128 _totalBorrowShares,
            uint256 _totalCollateral
        ) = fraxlendPairHelper.getPairAccounting(address(_fraxlendPair));
        final_.totalAssetAmount = _totalAssetAmount;
        final_.totalAssetShares = _totalAssetShares;
        final_.totalBorrowAmount = _totalBorrowAmount;
        final_.totalBorrowShares = _totalBorrowShares;
        final_.totalCollateral = _totalCollateral;
    }

    function setNetAccountingSnapshot(PairAccounting memory _first, PairAccounting memory _second)
        internal
    {
        net.totalAssetAmount = _first.totalAssetAmount - _second.totalAssetAmount;
        net.totalAssetShares = _first.totalAssetShares - _second.totalAssetShares;
        net.totalBorrowAmount = _first.totalBorrowAmount - _second.totalBorrowAmount;
        net.totalBorrowShares = _first.totalBorrowShares - _second.totalBorrowShares;
        net.totalCollateral = _first.totalCollateral - _second.totalCollateral;
    }

    /// @notice The ```defaultRateInitForLinear``` function generates some default init data for use
    /// in deployments
    function defaultRateInitForLinear() public view returns (bytes memory) {
        (uint256 MIN_INT,,, uint256 UTIL_PREC) =
            abi.decode(linearRateContract.getConstants(), (uint256, uint256, uint256, uint256));
        uint256 _minInterest = MIN_INT;
        uint256 _vertexInterest = 79_123_523 * 40; // ~10%
        uint256 _maxInterest = 79_123_523 * 400; // ~100%
        uint256 _vertexUtilization = (80 * UTIL_PREC) / 100;
        return abi.encode(_minInterest, _vertexInterest, _maxInterest, _vertexUtilization);
    }

    /// @notice The ```deployNonDynamicExternalContracts``` function deploys all contracts other
    /// than the pairs using default values
    /// @dev
    function deployNonDynamicExternalContracts() public {
        fraxlendPairHelper = new FraxlendPairHelper();

        deployer = new FraxlendPairDeployer();

        deployer.initialize(
            address(this), CIRCUIT_BREAKER_ADDRESS, COMPTROLLER_ADDRESS, TIME_LOCK_ADDRESS
        );

        deployer.setCreationCode(type(FraxlendPair).creationCode);

        variableRateContract = new VariableInterestRate();
        linearRateContract = new LinearInterestRate();
        console.log(
            "file: BasePairTest.sol ~ line 109 ~ deployNonDynamicExternalContracts ~ linearRateContract",
            address(linearRateContract)
        );
    }

    function fuzzyRateCalculator(
        uint256 _calcNum,
        uint256 _minInterest,
        uint256 _vertexInterest,
        uint256 _maxInterest,
        uint256 _vertexUtilization
    ) public view returns (address _rateContract, bytes memory _rateInitCallData) {
        uint256 _calculator = _calcNum % 2;
        if (_calculator == 1) {
            return (address(variableRateContract), abi.encode());
        } else {
            return (
                address(linearRateContract),
                abi.encode(
                    uint256(_minInterest),
                    uint256(_vertexInterest),
                    uint256(_maxInterest),
                    uint256(_vertexUtilization)
                    )
            );
        }
    }

    function setExternalContracts() public {
        vm.startPrank(address(this));
        deployNonDynamicExternalContracts();
        vm.stopPrank();
        // Deploy contracts
        collateral = IERC20(WETH_ERC20);
        asset = IERC20(FRAX_ERC20);
        oracleDivide = AggregatorV3Interface(CHAINLINK_ETH_USD);
    }

    /// @notice The ```deployFraxlendPublic``` function helps deploy Fraxlend public pairs with
    /// default config
    function deployFraxlendPublic(
        uint256 _normalization,
        address _rateContract,
        bytes memory _initRateData
    ) public {
        vm.prank(address(this));
        address _pairAddress = deployer.deploy(
            abi.encode(
                address(asset),
                address(collateral),
                address(oracleMultiply),
                address(oracleDivide),
                _normalization,
                address(_rateContract),
                _initRateData
            )
        );
        pair = FraxlendPair(_pairAddress);

        startHoax(COMPTROLLER_ADDRESS);
        pair.setSwapper(UNIV2_ROUTER, true);
        vm.stopPrank();

        startHoax(TIME_LOCK_ADDRESS);
        pair.changeFee(uint16((10 * FEE_PRECISION) / 100));
        vm.stopPrank();
    }

    function _encodeConfigData(
        uint256 _normalization,
        address _rateContract,
        bytes memory _initRateData
    ) internal view returns (bytes memory _configData) {
        _configData = abi.encode(
            address(asset),
            address(collateral),
            address(oracleMultiply),
            address(oracleDivide),
            _normalization,
            _rateContract,
            _initRateData
        );
    }

    function deployFraxlendCustom(
        uint256 _normalization,
        address _rateContractAddress,
        bytes memory _initRateData,
        uint256 _maxLTV,
        uint256 _liquidationFee,
        uint256 _maturity,
        uint256 _penaltyRate,
        address[] memory _approvedBorrowers,
        address[] memory _approvedLenders
    ) public {
        {
            pair = FraxlendPair(
                deployer.deployCustom(
                    "testname",
                    _encodeConfigData(_normalization, _rateContractAddress, _initRateData),
                    _maxLTV,
                    _liquidationFee,
                    _maturity,
                    _penaltyRate,
                    _approvedBorrowers,
                    _approvedLenders
                )
            );
        }

        startHoax(COMPTROLLER_ADDRESS);
        pair.setSwapper(UNIV2_ROUTER, true);
        vm.stopPrank();

        startHoax(TIME_LOCK_ADDRESS);
        pair.changeFee(uint16((10 * FEE_PRECISION) / 100));
        vm.stopPrank();
    }

    /// @notice The ```defaultSetUp``` function provides a full default deployment environment for
    /// testing
    function defaultSetUp() public virtual {
        setExternalContracts();
        // Set initial oracle prices
        deployFraxlendPublic(1e10, address(variableRateContract), abi.encode());
    }

    // helper to convert assets shares to amount
    function toAssetAmount(uint256 _shares, bool roundup) public view returns (uint256 _amount) {
        (uint256 _amountTotal, uint256 _sharesTotal) = pair.totalAsset();
        _amount = toAssetAmount(_amountTotal, _sharesTotal, _shares, roundup);
    }

    // helper to convert assets shares to amount
    function toAssetAmount(
        uint256 _amountTotal,
        uint256 _sharesTotal,
        uint256 _shares,
        bool roundup
    ) public pure returns (uint256 _amount) {
        if (_sharesTotal == 0) {
            _amount = _shares;
        } else {
            _amount = (_shares * _amountTotal) / _sharesTotal;
            if (roundup && (_amount * _sharesTotal) / _amountTotal < _shares) _amount++;
        }
    }

    // helper to convert borrows shares to amount
    function toBorrowAmount(uint256 _shares, bool roundup) public view returns (uint256 _amount) {
        (uint256 _amountTotal, uint256 _sharesTotal) = pair.totalBorrow();
        _amount = toBorrowAmount(_amountTotal, _sharesTotal, _shares, roundup);
    }

    // helper to convert borrows shares to amount
    function toBorrowAmount(
        uint256 _amountTotal,
        uint256 _sharesTotal,
        uint256 _shares,
        bool roundup
    ) public pure returns (uint256 _amount) {
        if (_sharesTotal == 0) {
            _amount = _shares;
        } else {
            _amount = (_shares * _amountTotal) / _sharesTotal;
            if (roundup && (_amount * _sharesTotal) / _amountTotal < _shares) _amount++;
        }
    }

    // helper to convert asset amount to shares
    function toAssetShares(uint256 _amount, bool roundup) public view returns (uint256 _shares) {
        (uint256 _amountTotal, uint256 _sharesTotal) = pair.totalAsset();
        _shares = toAssetShares(_amountTotal, _sharesTotal, _amount, roundup);
    }

    // helper to convert asset amount to shares
    function toAssetShares(
        uint256 _amountTotal,
        uint256 _sharesTotal,
        uint256 _amount,
        bool roundup
    ) public pure returns (uint256 _shares) {
        if (_amountTotal == 0) {
            _shares = _amount;
        } else {
            _shares = (_amount * _sharesTotal) / _amountTotal;
            if (roundup && (_shares * _amountTotal) / _sharesTotal < _amount) _shares++;
        }
    }

    // helper to convert borrow amount to shares
    function toBorrowShares(uint256 _amount, bool roundup) public view returns (uint256 _shares) {
        (uint256 _amountTotal, uint256 _sharesTotal) = pair.totalBorrow();
        _shares = toBorrowShares(_amountTotal, _sharesTotal, _amount, roundup);
    }

    // helper to convert borrow amount to shares
    function toBorrowShares(
        uint256 _amountTotal,
        uint256 _sharesTotal,
        uint256 _amount,
        bool roundup
    ) public pure returns (uint256 _shares) {
        if (_amountTotal == 0) {
            _shares = _amount;
        } else {
            _shares = (_amount * _sharesTotal) / _amountTotal;
            if (roundup && (_shares * _amountTotal) / _sharesTotal < _amount) _shares++;
        }
    }

    // helper to faucet funds to ERC20 contracts if no users give to all
    function faucetFunds(IERC20 _contract, uint256 _amount) internal {
        uint256 _length = users.length; // gas savings, good habit
        for (uint256 i = 0; i < _length; i++) {
            stdstore.target(address(_contract)).sig(_contract.balanceOf.selector).with_key(users[i])
                .checked_write(_amount);
        }
    }

    // helper to faucet funds to ERC20 contracts
    function faucetFunds(IERC20 _contract, uint256 _amount, address _user) internal {
        stdstore.target(address(_contract)).sig(_contract.balanceOf.selector).with_key(_user)
            .checked_write(_amount);
    }

    struct LendAction {
        address user;
        uint256 lendAmount;
    }

    // helper to approve and lend in one step
    function lendTokenViaDeposit(uint256 _amount, address _user) internal returns (uint256) {
        vm.startPrank(_user);
        asset.approve(address(pair), _amount);
        pair.deposit(_amount, _user);
        vm.stopPrank();
        return pair.balanceOf(_user);
    }

    // helper to approve and lend in one step
    function lendTokenViaDeposit(FraxlendPair _pair, uint256 _amount, address _user)
        internal
        returns (uint256)
    {
        startHoax(_user);
        IERC20(_pair.asset()).approve(address(_pair), _amount);
        _pair.deposit(_amount, _user);
        vm.stopPrank();
        return pair.balanceOf(_user);
    }

    function lendTokenViaDepositWithFaucet(FraxlendPair _pair, LendAction memory _lendAction)
        internal
        returns (uint256)
    {
        faucetFunds(IERC20(_pair.asset()), _lendAction.lendAmount, _lendAction.user);
        console.log(
            "file: BasePairTest.sol ~ line 408 ~ )internalreturns ~ _lendAction.user",
            _lendAction.user
        );
        return lendTokenViaDeposit(_pair, _lendAction.lendAmount, _lendAction.user);
    }

    // helper to approve and lend in one step
    function lendTokenViaMint(uint256 _shares, address _user) internal returns (uint256) {
        vm.startPrank(_user);
        uint256 _amount = pair.toAssetAmount(_shares, false);
        asset.approve(address(pair), _amount);
        pair.deposit(_amount, _user);
        vm.stopPrank();
        return pair.balanceOf(_user);
    }

    struct BorrowAction {
        address user;
        uint256 borrowAmount;
        uint256 collateralAmount;
    }

    // helper to approve and lend in one step
    function borrowToken(uint256 _amountToBorrow, uint256 _collateralAmount, address _user)
        internal
        returns (uint256 _finalShares, uint256 _finalCollateralBalance)
    {
        vm.startPrank(_user);
        collateral.approve(address(pair), _collateralAmount);
        pair.borrowAsset(uint128(_amountToBorrow), _collateralAmount, _user);
        _finalShares = pair.userBorrowShares(_user);
        _finalCollateralBalance = pair.userCollateralBalance(_user);
        vm.stopPrank();
    }

    function borrowTokenWithFaucet(FraxlendPair _fraxlendPair, BorrowAction memory _borrowAction)
        internal
        returns (uint256 _finalShares, uint256 _finalCollateralBalance)
    {
        faucetFunds(
            _fraxlendPair.collateralContract(), _borrowAction.collateralAmount, _borrowAction.user
        );
        (_finalShares, _finalCollateralBalance) = borrowToken(
            _borrowAction.borrowAmount, _borrowAction.collateralAmount, _borrowAction.user
        );
    }

    // helper to approve and repay in one step, should have called addInterest before hand
    function repayToken(uint256 _sharesToRepay, address _user)
        internal
        returns (uint256 _finalShares)
    {
        vm.startPrank(_user);
        uint256 _amountToApprove = toBorrowAmount(_sharesToRepay, true);
        asset.approve(address(pair), _amountToApprove);
        pair.repayAsset(_sharesToRepay, _user);
        _finalShares = pair.userBorrowShares(_user);
        vm.stopPrank();
    }

    // helper to move forward one block
    function mineOneBlock() internal {
        vm.warp(block.timestamp + 15);
        vm.roll(block.number + 1);
    }

    // helper to move forward multiple blocks
    function mineBlocks(uint256 _blocks) internal {
        vm.warp(block.timestamp + (15 * _blocks));
        vm.roll(block.number + _blocks);
    }

    // helper to move forward multiple blocks and add interest each time
    function addInterestAndMineBulk(uint256 _blocks) internal returns (uint256 _sumOfInt) {
        _sumOfInt = 0;
        for (uint256 i = 0; i < _blocks; i++) {
            mineOneBlock();
            (uint256 _interestEarned,,,) = pair.addInterest();
            _sumOfInt += _interestEarned;
        }
    }

    function getUtilization() internal view returns (uint256 _utilization) {
        (uint256 _borrowAmount,) = pair.totalBorrow();
        (uint256 _assetAmount,) = pair.totalAsset();
        _utilization = (_borrowAmount * UTIL_PREC) / _assetAmount;
    }

    // helper
    function interestCalculator(
        bytes memory _constants,
        uint256 _utilization,
        uint256 _currentInterestPerSecond,
        uint256 _elapsedTime
    ) internal pure returns (uint256) {
        (
            uint32 MIN_UTIL,
            uint32 MAX_UTIL,
            uint32 UTIL_PREC,
            uint64 MIN_INT,
            uint64 MAX_INT,
            uint256 INT_HALF_LIFE
        ) = abi.decode(_constants, (uint32, uint32, uint32, uint64, uint64, uint256));
        if (_utilization < MIN_UTIL) {
            uint256 _deltaUtilization = ((MIN_UTIL - _utilization) * 1e18) / MIN_UTIL;

            uint256 _decay = INT_HALF_LIFE + (_deltaUtilization * _deltaUtilization * _elapsedTime);
            _currentInterestPerSecond = (_currentInterestPerSecond * INT_HALF_LIFE) / _decay;

            if (_currentInterestPerSecond < MIN_INT) _currentInterestPerSecond = MIN_INT;
        } else if (_utilization > MAX_UTIL) {
            uint256 _deltaUtilization = ((_utilization - MAX_UTIL) * 1e18) / (UTIL_PREC - MAX_UTIL);
            uint256 _growth = INT_HALF_LIFE + (_deltaUtilization * _deltaUtilization * _elapsedTime);
            _currentInterestPerSecond = (_currentInterestPerSecond * _growth) / INT_HALF_LIFE;

            if (_currentInterestPerSecond > MAX_INT) _currentInterestPerSecond = MAX_INT;
        }
        return _currentInterestPerSecond;
    }

    function exchangeRate(FraxlendPair _pair) internal view returns (uint224 _exchangeRate) {
        (, _exchangeRate) = _pair.exchangeRateInfo();
    }

    function ratePerSec(FraxlendPair _pair) internal view returns (uint64 _ratePerSec) {
        (,,, _ratePerSec) = _pair.currentRateInfo();
    }

    function feeToProtocolRate(FraxlendPair _pair)
        internal
        view
        returns (uint64 _feeToProtocolRate)
    {
        (, _feeToProtocolRate,,) = _pair.currentRateInfo();
    }

    function getCollateralAmount(uint256 _borrowAmount, uint256 _exchangeRate, uint256 _targetLTV)
        internal
        pure
        returns (uint256 _collateralAmount)
    {
        _collateralAmount =
            (_borrowAmount * _exchangeRate * LTV_PRECISION) / (_targetLTV * EXCHANGE_PRECISION);
    }
}
