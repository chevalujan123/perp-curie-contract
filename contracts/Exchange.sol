// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SignedSafeMath } from "@openzeppelin/contracts/math/SignedSafeMath.sol";
import { TransferHelper } from "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import { FullMath } from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { SwapMath } from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";
import { LiquidityMath } from "@uniswap/v3-core/contracts/libraries/LiquidityMath.sol";
import { FixedPoint128 } from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { LiquidityAmounts } from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import { ArbBlockContext } from "./arbitrum/ArbBlockContext.sol";
import { UniswapV3Broker } from "./lib/UniswapV3Broker.sol";
import { PerpSafeCast } from "./lib/PerpSafeCast.sol";
import { FeeMath } from "./lib/FeeMath.sol";
import { PerpFixedPoint96 } from "./lib/PerpFixedPoint96.sol";
import { Funding } from "./lib/Funding.sol";
import { PerpMath } from "./lib/PerpMath.sol";
import { OrderKey } from "./lib/OrderKey.sol";
import { Tick } from "./lib/Tick.sol";
import { SafeOwnable } from "./base/SafeOwnable.sol";
import { IERC20Metadata } from "./interface/IERC20Metadata.sol";

contract Exchange is IUniswapV3MintCallback, IUniswapV3SwapCallback, SafeOwnable, ArbBlockContext {
    using SafeMath for uint256;
    using SafeMath for uint128;
    using SignedSafeMath for int256;
    using PerpMath for uint256;
    using PerpMath for int256;
    using PerpMath for uint160;
    using PerpSafeCast for uint256;
    using PerpSafeCast for uint128;
    using PerpSafeCast for int256;
    using Tick for mapping(int24 => Tick.GrowthInfo);

    //
    // EVENT
    //
    event PoolAdded(address indexed baseToken, uint24 indexed feeRatio, address indexed pool);
    event LiquidityChanged(
        address indexed maker,
        address indexed baseToken,
        address indexed quoteToken,
        int24 lowerTick,
        int24 upperTick,
        // amount of base token added to the liquidity (excl. fee) (+: add liquidity, -: remove liquidity)
        int256 base,
        // amount of quote token added to the liquidity (excl. fee) (+: add liquidity, -: remove liquidity)
        int256 quote,
        int128 liquidity, // amount of liquidity unit added (+: add liquidity, -: remove liquidity)
        uint256 quoteFee // amount of quote token the maker received as fee
    );

    //
    // STRUCT
    //
    struct InternalAddLiquidityToOrderParams {
        address maker;
        address baseToken;
        address pool;
        int24 lowerTick;
        int24 upperTick;
        uint256 feeGrowthGlobalClearingHouseX128;
        uint256 feeGrowthInsideQuoteX128;
        uint128 liquidity;
        Funding.Growth globalFundingGrowth;
    }

    /// @param feeGrowthInsideClearingHouseLastX128 there is only quote fee in ClearingHouse
    struct OpenOrder {
        uint128 liquidity;
        int24 lowerTick;
        int24 upperTick;
        uint256 feeGrowthInsideClearingHouseLastX128;
        int256 lastTwPremiumGrowthInsideX96;
        int256 lastTwPremiumGrowthBelowX96;
        int256 lastTwPremiumDivBySqrtPriceGrowthInsideX96;
    }

    struct ReplaySwapParams {
        address baseToken;
        bool isBaseToQuote;
        bool isExactInput;
        uint256 amount;
        uint160 sqrtPriceLimitX96;
    }

    struct AddLiquidityParams {
        address trader;
        address baseToken;
        uint256 base;
        uint256 quote;
        int24 lowerTick;
        int24 upperTick;
        Funding.Growth updatedGlobalFundingGrowth;
    }

    struct AddLiquidityResponse {
        uint256 base;
        uint256 quote;
        uint256 fee;
        uint128 liquidity;
    }

    struct SwapParams {
        address trader;
        address baseToken;
        bool isBaseToQuote;
        bool isExactInput;
        uint256 amount;
        uint160 sqrtPriceLimitX96; // price slippage protection
        Funding.Growth updatedGlobalFundingGrowth;
    }

    struct SwapResponse {
        int256 exchangedPositionSize;
        int256 exchangedPositionNotional;
        uint256 fee;
        uint256 insuranceFundFee;
    }

    struct MintCallbackData {
        address trader;
        address baseToken;
        address pool;
    }

    struct SwapCallbackData {
        address trader;
        address baseToken;
        address pool;
        uint24 uniswapFeeRatio;
        uint256 fee;
    }

    struct RemoveLiquidityParams {
        address maker;
        address baseToken;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
    }

    struct RemoveLiquidityResponse {
        uint256 base;
        uint256 quote;
        uint256 fee;
    }

    struct InternalRemoveLiquidityFromOrderParams {
        address maker;
        address baseToken;
        address pool;
        int24 lowerTick;
        int24 upperTick;
        uint256 feeGrowthInsideQuoteX128;
        uint128 liquidity;
    }

    struct SwapStep {
        uint160 initialSqrtPriceX96;
        int24 nextTick;
        bool isNextTickInitialized;
        uint160 nextSqrtPriceX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    struct InternalReplaySwapParams {
        UniswapV3Broker.SwapState state;
        address baseToken;
        bool isBaseToQuote;
        bool shouldUpdateState;
        uint160 sqrtPriceLimitX96;
        uint24 exchangeFeeRatio;
        uint24 uniswapFeeRatio;
        Funding.Growth globalFundingGrowth;
    }

    struct ReplaySwapResponse {
        int24 tick;
        uint256 fee; // exchangeFeeRatio
        uint256 insuranceFundFee; // insuranceFundFee = exchangeFeeRatio * insuranceFundFeeRatio
    }

    address public immutable quoteToken;
    address public immutable uniswapV3Factory;
    address public clearingHouse;

    uint8 public maxOrdersPerMarket;

    // key: base token, value: pool
    mapping(address => address) internal _poolMap;

    // first key: trader, second key: base token
    mapping(address => mapping(address => bytes32[])) internal _openOrderIdsMap;

    // key: openOrderId
    mapping(bytes32 => OpenOrder) internal _openOrderMap;

    // first key: base token, second key: tick index
    // value: the accumulator of **Tick.GrowthInfo** outside each tick of each pool
    mapping(address => mapping(int24 => Tick.GrowthInfo)) internal _growthOutsideTickMap;

    // key: base token
    // value: the global accumulator of **quote fee transformed from base fee** of each pool
    mapping(address => uint256) internal _feeGrowthGlobalX128Map;

    // key: baseToken, what insurance fund get = exchangeFee * insuranceFundFeeRatio
    mapping(address => uint24) internal _insuranceFundFeeRatioMap;

    // key: pool, _uniswapFeeRatioMap cache only
    mapping(address => uint24) internal _uniswapFeeRatioMap;

    // key: pool , uniswap fee will be ignored and use the exchangeFeeRatio instead
    mapping(address => uint24) internal _exchangeFeeRatioMap;

    constructor(
        address clearingHouseArg,
        address uniswapV3FactoryArg,
        address quoteTokenArg
    ) public {
        // ClearingHouse is 0
        require(clearingHouseArg != address(0), "EX_CH0");
        // UnsiwapV3Factory is 0
        require(uniswapV3FactoryArg != address(0), "EX_UF0");
        // QuoteToken is 0
        require(quoteTokenArg != address(0), "EX_QT0");

        // update states
        clearingHouse = clearingHouseArg;
        uniswapV3Factory = uniswapV3FactoryArg;
        quoteToken = quoteTokenArg;
    }

    //
    // MODIFIERS
    //
    modifier onlyClearingHouse() {
        // only ClearingHouse
        require(_msgSender() == clearingHouse, "EX_OCH");
        _;
    }

    modifier checkRatio(uint24 ratio) {
        // EX_RO: ratio overflow
        require(ratio <= 1e6, "EX_RO");
        _;
    }

    //
    // EXTERNAL ADMIN FUNCTIONS
    //

    function setMaxOrdersPerMarket(uint8 maxOrdersPerMarketArg) external onlyOwner {
        maxOrdersPerMarket = maxOrdersPerMarketArg;
    }

    function setFeeRatio(address baseToken, uint24 feeRatio) external onlyOwner checkRatio(feeRatio) {
        _exchangeFeeRatioMap[_poolMap[baseToken]] = feeRatio;
    }

    function setInsuranceFundFeeRatio(address baseToken, uint24 insuranceFundFeeRatioArg)
        external
        checkRatio(insuranceFundFeeRatioArg)
        onlyOwner
    {
        _insuranceFundFeeRatioMap[baseToken] = insuranceFundFeeRatioArg;
    }

    function addPool(address baseToken, uint24 feeRatio) external onlyOwner returns (address) {
        // EX_BDN18: baseToken decimals is not 18
        require(IERC20Metadata(baseToken).decimals() == 18, "EX_BDN18");
        // to ensure the base is always token0 and quote is always token1
        // EX_IB: invalid baseToken
        require(baseToken < quoteToken, "EX_IB");

        address pool = UniswapV3Broker.getPool(uniswapV3Factory, quoteToken, baseToken, feeRatio);
        // EX_NEP: non-existent pool in uniswapV3 factory
        require(pool != address(0), "EX_NEP");
        // EX_EP: existent pool in ClearingHouse
        require(_poolMap[baseToken] == address(0), "EX_EP");
        // EX_PNI: pool not (yet) initialized
        require(UniswapV3Broker.getSqrtMarkPriceX96(pool) != 0, "EX_PNI");

        _poolMap[baseToken] = pool;
        _uniswapFeeRatioMap[pool] = feeRatio;
        _exchangeFeeRatioMap[pool] = feeRatio;

        emit PoolAdded(baseToken, feeRatio, pool);
        return pool;
    }

    //
    // EXTERNAL FUNCTIONS
    //
    function swap(SwapParams memory params) external onlyClearingHouse returns (SwapResponse memory) {
        address pool = _poolMap[params.baseToken];
        uint24 uniswapFeeRatio = _uniswapFeeRatioMap[pool];

        (uint256 scaledAmountForUniswapV3PoolSwap, int256 signedScaledAmountForReplaySwap) =
            _getScaledAmountForSwaps(
                params.isBaseToQuote,
                params.isExactInput,
                params.amount,
                _exchangeFeeRatioMap[pool],
                uniswapFeeRatio
            );

        // simulate the swap to calculate the fees charged in exchange
        ReplaySwapResponse memory replayResponse =
            _replaySwap(
                InternalReplaySwapParams({
                    state: UniswapV3Broker.getSwapState(
                        pool,
                        signedScaledAmountForReplaySwap,
                        _feeGrowthGlobalX128Map[params.baseToken]
                    ),
                    baseToken: params.baseToken,
                    isBaseToQuote: params.isBaseToQuote,
                    shouldUpdateState: true,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    exchangeFeeRatio: _exchangeFeeRatioMap[pool],
                    uniswapFeeRatio: uniswapFeeRatio,
                    globalFundingGrowth: params.updatedGlobalFundingGrowth
                })
            );
        UniswapV3Broker.SwapResponse memory response =
            UniswapV3Broker.swap(
                UniswapV3Broker.SwapParams(
                    pool,
                    params.isBaseToQuote,
                    params.isExactInput,
                    // mint extra base token before swap
                    scaledAmountForUniswapV3PoolSwap,
                    params.sqrtPriceLimitX96,
                    abi.encode(
                        SwapCallbackData({
                            trader: params.trader,
                            baseToken: params.baseToken,
                            pool: pool,
                            fee: replayResponse.fee,
                            uniswapFeeRatio: _uniswapFeeRatioMap[pool]
                        })
                    )
                )
            );

        // 1. mint/burn in exchange (but swapCallback has some tokenInfo logic, need to update swap's return
        address outputToken = params.isBaseToQuote ? quoteToken : params.baseToken;
        uint256 outputAmount = params.isBaseToQuote ? response.quote : response.base;
        TransferHelper.safeTransfer(outputToken, clearingHouse, outputAmount);

        // because we charge fee in CH instead of uniswap pool,
        // we need to scale up base or quote amount to get exact exchanged position size and notional
        int256 exchangedPositionSize;
        int256 exchangedPositionNotional;
        if (params.isBaseToQuote) {
            // short: exchangedPositionSize <= 0 && exchangedPositionNotional >= 0
            exchangedPositionSize = -(
                FeeMath.calcAmountScaledByFeeRatio(response.base, uniswapFeeRatio, false).toInt256()
            );
            // due to base to quote fee, exchangedPositionNotional contains the fee
            // s.t. we can take the fee away from exchangedPositionNotional
            exchangedPositionNotional = response.quote.toInt256();
        } else {
            // long: exchangedPositionSize >= 0 && exchangedPositionNotional <= 0
            exchangedPositionSize = response.base.toInt256();
            exchangedPositionNotional = -(
                FeeMath.calcAmountScaledByFeeRatio(response.quote, uniswapFeeRatio, false).toInt256()
            );
        }

        return
            SwapResponse({
                exchangedPositionSize: exchangedPositionSize,
                exchangedPositionNotional: exchangedPositionNotional,
                fee: replayResponse.fee,
                insuranceFundFee: replayResponse.insuranceFundFee
            });
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        onlyClearingHouse
        returns (AddLiquidityResponse memory)
    {
        address pool = _poolMap[params.baseToken];
        uint256 feeGrowthGlobalClearingHouseX128 = _feeGrowthGlobalX128Map[params.baseToken];
        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[params.baseToken];
        UniswapV3Broker.AddLiquidityResponse memory response;

        {
            bool initializedBeforeLower = UniswapV3Broker.getIsTickInitialized(pool, params.lowerTick);
            bool initializedBeforeUpper = UniswapV3Broker.getIsTickInitialized(pool, params.upperTick);

            // add liquidity to liquidity pool
            response = UniswapV3Broker.addLiquidity(
                UniswapV3Broker.AddLiquidityParams(
                    pool,
                    params.baseToken,
                    quoteToken,
                    params.lowerTick,
                    params.upperTick,
                    params.base,
                    params.quote,
                    abi.encode(MintCallbackData(params.trader, params.baseToken, pool))
                )
            );
            // mint callback

            int24 currentTick = UniswapV3Broker.getTick(pool);
            // initialize tick info
            if (!initializedBeforeLower && UniswapV3Broker.getIsTickInitialized(pool, params.lowerTick)) {
                tickMap.initialize(
                    params.lowerTick,
                    currentTick,
                    Tick.GrowthInfo(
                        feeGrowthGlobalClearingHouseX128,
                        params.updatedGlobalFundingGrowth.twPremiumX96,
                        params.updatedGlobalFundingGrowth.twPremiumDivBySqrtPriceX96
                    )
                );
            }
            if (!initializedBeforeUpper && UniswapV3Broker.getIsTickInitialized(pool, params.upperTick)) {
                tickMap.initialize(
                    params.upperTick,
                    currentTick,
                    Tick.GrowthInfo(
                        feeGrowthGlobalClearingHouseX128,
                        params.updatedGlobalFundingGrowth.twPremiumX96,
                        params.updatedGlobalFundingGrowth.twPremiumDivBySqrtPriceX96
                    )
                );
            }
        }

        // mutate states
        uint256 fee =
            _addLiquidityToOrder(
                InternalAddLiquidityToOrderParams({
                    maker: params.trader,
                    baseToken: params.baseToken,
                    pool: pool,
                    lowerTick: params.lowerTick,
                    upperTick: params.upperTick,
                    feeGrowthGlobalClearingHouseX128: feeGrowthGlobalClearingHouseX128,
                    feeGrowthInsideQuoteX128: response.feeGrowthInsideQuoteX128,
                    liquidity: response.liquidity,
                    globalFundingGrowth: params.updatedGlobalFundingGrowth
                })
            );

        emit LiquidityChanged(
            params.trader,
            params.baseToken,
            quoteToken,
            params.lowerTick,
            params.upperTick,
            response.base.toInt256(),
            response.quote.toInt256(),
            response.liquidity.toInt128(),
            fee
        );

        return
            AddLiquidityResponse({
                base: response.base,
                quote: response.quote,
                fee: fee,
                liquidity: response.liquidity
            });
    }

    function removeLiquidityByIds(
        address maker,
        address baseToken,
        bytes32[] calldata orderIds
    ) external onlyClearingHouse returns (RemoveLiquidityResponse memory) {
        uint256 totalBase;
        uint256 totalQuote;
        uint256 totalFee;
        for (uint256 i = 0; i < orderIds.length; i++) {
            bytes32 orderId = orderIds[i];
            OpenOrder memory order = _openOrderMap[orderId];

            RemoveLiquidityResponse memory response =
                _removeLiquidity(
                    RemoveLiquidityParams({
                        maker: maker,
                        baseToken: baseToken,
                        lowerTick: order.lowerTick,
                        upperTick: order.upperTick,
                        liquidity: order.liquidity
                    })
                );

            totalBase = totalBase.add(response.base);
            totalQuote = totalQuote.add(response.quote);
            totalFee = totalFee.add(response.fee);
        }

        return RemoveLiquidityResponse({ base: totalBase, quote: totalQuote, fee: totalFee });
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        onlyClearingHouse
        returns (RemoveLiquidityResponse memory)
    {
        return _removeLiquidity(params);
    }

    /// @dev this is the non-view version of getLiquidityCoefficientInFundingPayment()
    function updateFundingGrowthAndLiquidityCoefficientInFundingPayment(
        address trader,
        address baseToken,
        Funding.Growth memory updatedGlobalFundingGrowth
    ) external onlyClearingHouse returns (int256) {
        bytes32[] memory orderIds = _openOrderIdsMap[trader][baseToken];
        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[baseToken];
        address pool = _poolMap[baseToken];

        // update funding of liquidity
        int256 liquidityCoefficientInFundingPayment;
        for (uint256 i = 0; i < orderIds.length; i++) {
            OpenOrder storage order = _openOrderMap[orderIds[i]];
            Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo =
                tickMap.getAllFundingGrowth(
                    order.lowerTick,
                    order.upperTick,
                    UniswapV3Broker.getTick(pool),
                    updatedGlobalFundingGrowth.twPremiumX96,
                    updatedGlobalFundingGrowth.twPremiumDivBySqrtPriceX96
                );

            // the calculation here is based on cached values
            liquidityCoefficientInFundingPayment = liquidityCoefficientInFundingPayment.add(
                _getLiquidityCoefficientInFundingPayment(order, fundingGrowthRangeInfo)
            );

            // thus, state updates have to come after
            order.lastTwPremiumGrowthInsideX96 = fundingGrowthRangeInfo.twPremiumGrowthInsideX96;
            order.lastTwPremiumGrowthBelowX96 = fundingGrowthRangeInfo.twPremiumGrowthBelowX96;
            order.lastTwPremiumDivBySqrtPriceGrowthInsideX96 = fundingGrowthRangeInfo
                .twPremiumDivBySqrtPriceGrowthInsideX96;
        }

        return liquidityCoefficientInFundingPayment;
    }

    // return the price after replay swap (final tick)
    function replaySwap(ReplaySwapParams memory params) external returns (int24) {
        address pool = _poolMap[params.baseToken];
        uint24 exchangeFeeRatio = _exchangeFeeRatioMap[pool];
        uint24 uniswapFeeRatio = _uniswapFeeRatioMap[pool];
        (, int256 signedScaledAmountForReplaySwap) =
            _getScaledAmountForSwaps(
                params.isBaseToQuote,
                params.isExactInput,
                params.amount,
                exchangeFeeRatio,
                uniswapFeeRatio
            );
        UniswapV3Broker.SwapState memory swapState =
            UniswapV3Broker.getSwapState(
                pool,
                signedScaledAmountForReplaySwap,
                _feeGrowthGlobalX128Map[params.baseToken]
            );

        // globalFundingGrowth can be empty if shouldUpdateState is false
        ReplaySwapResponse memory response =
            _replaySwap(
                InternalReplaySwapParams({
                    state: swapState,
                    baseToken: params.baseToken,
                    isBaseToQuote: params.isBaseToQuote,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                    exchangeFeeRatio: exchangeFeeRatio,
                    uniswapFeeRatio: uniswapFeeRatio,
                    shouldUpdateState: false,
                    globalFundingGrowth: Funding.Growth({ twPremiumX96: 0, twPremiumDivBySqrtPriceX96: 0 })
                })
            );
        return response.tick;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory callbackData = abi.decode(data, (MintCallbackData));
        // EX_FMV: failed mintCallback verification
        require(_msgSender() == _poolMap[callbackData.baseToken], "EX_FMV");

        IUniswapV3MintCallback(clearingHouse).uniswapV3MintCallback(amount0Owed, amount1Owed, data);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        SwapCallbackData memory callbackData = abi.decode(data, (SwapCallbackData));
        // EX_FSV: failed swapCallback verification
        require(_msgSender() == _poolMap[callbackData.baseToken], "EX_FSV");

        IUniswapV3SwapCallback(clearingHouse).uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    //
    // EXTERNAL VIEW
    //

    function getPool(address baseToken) external view returns (address) {
        return _poolMap[baseToken];
    }

    function getFeeRatio(address baseToken) external view returns (uint24) {
        return _exchangeFeeRatioMap[_poolMap[baseToken]];
    }

    function getOpenOrderIds(address trader, address baseToken) external view returns (bytes32[] memory) {
        return _openOrderIdsMap[trader][baseToken];
    }

    function getOpenOrder(
        address trader,
        address baseToken,
        int24 lowerTick,
        int24 upperTick
    ) external view returns (OpenOrder memory) {
        return _openOrderMap[OrderKey.compute(trader, baseToken, lowerTick, upperTick)];
    }

    function getTick(address baseToken) external view returns (int24) {
        return UniswapV3Broker.getTick(_poolMap[baseToken]);
    }

    function hasOrder(address trader, address[] calldata tokens) external view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (_openOrderIdsMap[trader][tokens[i]].length > 0) {
                return true;
            }
        }
        return false;
    }

    /// @dev note the return value includes maker fee.
    ///      For more details please refer to _getTotalTokenAmountInPool() docstring
    function getTotalQuoteAmountInPools(address trader, address[] calldata baseTokens) external view returns (uint256) {
        uint256 totalQuoteAmountInPools;
        for (uint256 i = 0; i < baseTokens.length; i++) {
            address baseToken = baseTokens[i];
            uint256 quoteInPool = _getTotalTokenAmountInPool(trader, baseToken, false);
            totalQuoteAmountInPools = totalQuoteAmountInPools.add(quoteInPool);
        }
        return totalQuoteAmountInPools;
    }

    /// @dev the returned quote amount does not include funding payment because
    ///      the latter is counted directly toward realizedPnl.
    ///      please refer to _getTotalTokenAmountInPool() docstring for specs
    function getTotalTokenAmountInPool(
        address trader,
        address baseToken,
        bool fetchBase // true: fetch base amount, false: fetch quote amount
    ) external view returns (uint256 tokenAmount) {
        return _getTotalTokenAmountInPool(trader, baseToken, fetchBase);
    }

    function getSqrtMarkTwapX96(address baseToken, uint32 twapInterval) external view returns (uint160) {
        return UniswapV3Broker.getSqrtMarkTwapX96(_poolMap[baseToken], twapInterval);
    }

    /// @dev this is the view version of updateFundingGrowthAndLiquidityCoefficientInFundingPayment()
    function getLiquidityCoefficientInFundingPayment(
        address trader,
        address baseToken,
        Funding.Growth memory updatedGlobalFundingGrowth
    ) external view returns (int256) {
        bytes32[] memory orderIds = _openOrderIdsMap[trader][baseToken];
        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[baseToken];
        address pool = _poolMap[baseToken];

        int256 liquidityCoefficientInFundingPayment;

        for (uint256 i = 0; i < orderIds.length; i++) {
            OpenOrder memory order = _openOrderMap[orderIds[i]];
            Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo =
                tickMap.getAllFundingGrowth(
                    order.lowerTick,
                    order.upperTick,
                    UniswapV3Broker.getTick(pool),
                    updatedGlobalFundingGrowth.twPremiumX96,
                    updatedGlobalFundingGrowth.twPremiumDivBySqrtPriceX96
                );

            // the calculation here is based on cached values
            liquidityCoefficientInFundingPayment = liquidityCoefficientInFundingPayment.add(
                _getLiquidityCoefficientInFundingPayment(order, fundingGrowthRangeInfo)
            );
        }

        return liquidityCoefficientInFundingPayment;
    }

    //
    // INTERNAL
    //
    function _removeLiquidity(RemoveLiquidityParams memory params) internal returns (RemoveLiquidityResponse memory) {
        // load existing open order
        bytes32 orderId = OrderKey.compute(params.maker, params.baseToken, params.lowerTick, params.upperTick);
        OpenOrder storage openOrder = _openOrderMap[orderId];
        // EX_NEO non-existent openOrder
        require(openOrder.liquidity > 0, "EX_NEO");
        // EX_NEL not enough liquidity
        require(params.liquidity <= openOrder.liquidity, "EX_NEL");

        address pool = _poolMap[params.baseToken];
        UniswapV3Broker.RemoveLiquidityResponse memory response =
            UniswapV3Broker.removeLiquidity(
                UniswapV3Broker.RemoveLiquidityParams(pool, params.lowerTick, params.upperTick, params.liquidity)
            );

        // update token info based on existing open order
        uint256 fee =
            _removeLiquidityFromOrder(
                InternalRemoveLiquidityFromOrderParams({
                    maker: params.maker,
                    baseToken: params.baseToken,
                    pool: pool,
                    lowerTick: params.lowerTick,
                    upperTick: params.upperTick,
                    feeGrowthInsideQuoteX128: response.feeGrowthInsideQuoteX128,
                    liquidity: params.liquidity
                })
            );

        // if flipped from initialized to uninitialized, clear the tick info
        if (!UniswapV3Broker.getIsTickInitialized(pool, params.lowerTick)) {
            _growthOutsideTickMap[params.baseToken].clear(params.lowerTick);
        }
        if (!UniswapV3Broker.getIsTickInitialized(pool, params.upperTick)) {
            _growthOutsideTickMap[params.baseToken].clear(params.upperTick);
        }

        TransferHelper.safeTransfer(params.baseToken, clearingHouse, response.base);
        TransferHelper.safeTransfer(quoteToken, clearingHouse, response.quote);

        emit LiquidityChanged(
            params.maker,
            params.baseToken,
            quoteToken,
            params.lowerTick,
            params.upperTick,
            -response.base.toInt256(),
            -response.quote.toInt256(),
            -params.liquidity.toInt128(),
            fee
        );

        return RemoveLiquidityResponse({ base: response.base, quote: response.quote, fee: fee });
    }

    function _removeLiquidityFromOrder(InternalRemoveLiquidityFromOrderParams memory params)
        internal
        returns (uint256)
    {
        // update token info based on existing open order
        bytes32 orderId = OrderKey.compute(params.maker, params.baseToken, params.lowerTick, params.upperTick);
        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[params.baseToken];
        OpenOrder storage openOrder = _openOrderMap[orderId];
        uint256 feeGrowthInsideClearingHouseX128 =
            tickMap.getFeeGrowthInside(
                params.lowerTick,
                params.upperTick,
                UniswapV3Broker.getTick(params.pool),
                _feeGrowthGlobalX128Map[params.baseToken]
            );
        uint256 fee =
            _calcOwedFee(
                openOrder.liquidity,
                feeGrowthInsideClearingHouseX128,
                openOrder.feeGrowthInsideClearingHouseLastX128
            );

        // update open order with new liquidity
        openOrder.liquidity = openOrder.liquidity.sub(params.liquidity).toUint128();
        if (openOrder.liquidity == 0) {
            _removeOrder(params.maker, params.baseToken, orderId);
        } else {
            openOrder.feeGrowthInsideClearingHouseLastX128 = feeGrowthInsideClearingHouseX128;
        }

        return fee;
    }

    function _removeOrder(
        address maker,
        address baseToken,
        bytes32 orderId
    ) internal {
        bytes32[] storage orderIds = _openOrderIdsMap[maker][baseToken];
        uint256 idx;
        for (idx = 0; idx < orderIds.length; idx++) {
            if (orderIds[idx] == orderId) {
                // found the existing order ID
                // remove it from the array efficiently by re-ordering and deleting the last element
                orderIds[idx] = orderIds[orderIds.length - 1];
                orderIds.pop();
                break;
            }
        }
        delete _openOrderMap[orderId];
    }

    function _addLiquidityToOrder(InternalAddLiquidityToOrderParams memory params) internal returns (uint256) {
        // load existing open order
        bytes32 orderId = OrderKey.compute(params.maker, params.baseToken, params.lowerTick, params.upperTick);
        OpenOrder storage openOrder = _openOrderMap[orderId];

        uint256 feeGrowthInsideClearingHouseX128;
        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[params.baseToken];
        uint256 fee;
        if (openOrder.liquidity == 0) {
            // it's a new order
            bytes32[] storage orderIds = _openOrderIdsMap[params.maker][params.baseToken];
            // EX_ONE: orders number exceeded
            require(maxOrdersPerMarket == 0 || orderIds.length < maxOrdersPerMarket, "EX_ONE");
            orderIds.push(orderId);

            openOrder.lowerTick = params.lowerTick;
            openOrder.upperTick = params.upperTick;

            Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo =
                tickMap.getAllFundingGrowth(
                    openOrder.lowerTick,
                    openOrder.upperTick,
                    UniswapV3Broker.getTick(params.pool),
                    params.globalFundingGrowth.twPremiumX96,
                    params.globalFundingGrowth.twPremiumDivBySqrtPriceX96
                );
            openOrder.lastTwPremiumGrowthInsideX96 = fundingGrowthRangeInfo.twPremiumGrowthInsideX96;
            openOrder.lastTwPremiumGrowthBelowX96 = fundingGrowthRangeInfo.twPremiumGrowthBelowX96;
            openOrder.lastTwPremiumDivBySqrtPriceGrowthInsideX96 = fundingGrowthRangeInfo
                .twPremiumDivBySqrtPriceGrowthInsideX96;
        } else {
            feeGrowthInsideClearingHouseX128 = tickMap.getFeeGrowthInside(
                params.lowerTick,
                params.upperTick,
                UniswapV3Broker.getTick(params.pool),
                params.feeGrowthGlobalClearingHouseX128
            );
            fee = _calcOwedFee(
                openOrder.liquidity,
                feeGrowthInsideClearingHouseX128,
                openOrder.feeGrowthInsideClearingHouseLastX128
            );
        }

        // update open order with new liquidity
        openOrder.liquidity = openOrder.liquidity.add(params.liquidity).toUint128();
        openOrder.feeGrowthInsideClearingHouseLastX128 = feeGrowthInsideClearingHouseX128;

        return fee;
    }

    function _replaySwap(InternalReplaySwapParams memory params) internal returns (ReplaySwapResponse memory) {
        address pool = _poolMap[params.baseToken];
        bool isExactInput = params.state.amountSpecifiedRemaining > 0;
        uint24 insuranceFundFeeRatio = _insuranceFundFeeRatioMap[params.baseToken];
        uint256 feeResult; // exchangeFeeRatio
        uint256 insuranceFundFeeResult; // insuranceFundFee = exchangeFeeRatio * insuranceFundFeeRatio

        params.sqrtPriceLimitX96 = params.sqrtPriceLimitX96 == 0
            ? (params.isBaseToQuote ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
            : params.sqrtPriceLimitX96;

        // if there is residue in amountSpecifiedRemaining, makers can get a tiny little bit less than expected,
        // which is safer for the system
        while (params.state.amountSpecifiedRemaining != 0 && params.state.sqrtPriceX96 != params.sqrtPriceLimitX96) {
            SwapStep memory step;
            step.initialSqrtPriceX96 = params.state.sqrtPriceX96;

            // find next tick
            // note the search is bounded in one word
            (step.nextTick, step.isNextTickInitialized) = UniswapV3Broker.getNextInitializedTickWithinOneWord(
                pool,
                params.state.tick,
                UniswapV3Broker.getTickSpacing(pool),
                params.isBaseToQuote
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.nextTick < TickMath.MIN_TICK) {
                step.nextTick = TickMath.MIN_TICK;
            } else if (step.nextTick > TickMath.MAX_TICK) {
                step.nextTick = TickMath.MAX_TICK;
            }

            // get the next price of this step (either next tick's price or the ending price)
            // use sqrtPrice instead of tick is more precise
            step.nextSqrtPriceX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            // find the next swap checkpoint
            // (either reached the next price of this step, or exhausted remaining amount specified)
            (params.state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                params.state.sqrtPriceX96,
                (
                    params.isBaseToQuote
                        ? step.nextSqrtPriceX96 < params.sqrtPriceLimitX96
                        : step.nextSqrtPriceX96 > params.sqrtPriceLimitX96
                )
                    ? params.sqrtPriceLimitX96
                    : step.nextSqrtPriceX96,
                params.state.liquidity,
                params.state.amountSpecifiedRemaining,
                // isBaseToQuote: fee is charged in base token in uniswap pool; thus, use uniswapFeeRatio to replay
                // !isBaseToQuote: fee is charged in quote token in clearing house; thus, use exchangeFeeRatioRatio
                params.isBaseToQuote ? params.uniswapFeeRatio : params.exchangeFeeRatio
            );

            // user input 1 quote:
            // quote token to uniswap ===> 1*0.98/0.99 = 0.98989899
            // fee = 0.98989899 * 2% = 0.01979798
            if (isExactInput) {
                params.state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                params.state.amountSpecifiedRemaining += step.amountOut.toInt256();
            }

            // update CH's global fee growth if there is liquidity in this range
            // note CH only collects quote fee when swapping base -> quote
            if (params.state.liquidity > 0) {
                if (params.isBaseToQuote) {
                    step.feeAmount = FullMath.mulDivRoundingUp(step.amountOut, params.exchangeFeeRatio, 1e6);
                }

                feeResult += step.feeAmount;
                uint256 stepInsuranceFundFee = FullMath.mulDivRoundingUp(step.feeAmount, insuranceFundFeeRatio, 1e6);
                insuranceFundFeeResult += stepInsuranceFundFee;
                uint256 stepMakerFee = step.feeAmount.sub(stepInsuranceFundFee);
                params.state.feeGrowthGlobalX128 += FullMath.mulDiv(
                    stepMakerFee,
                    FixedPoint128.Q128,
                    params.state.liquidity
                );
            }

            if (params.state.sqrtPriceX96 == step.nextSqrtPriceX96) {
                // we have reached the tick's boundary
                if (step.isNextTickInitialized) {
                    if (params.shouldUpdateState) {
                        // update the tick if it has been initialized
                        mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[params.baseToken];
                        // according to the above updating logic,
                        // if isBaseToQuote, state.feeGrowthGlobalX128 will be updated; else, will never be updated
                        tickMap.cross(
                            step.nextTick,
                            Tick.GrowthInfo({
                                feeX128: params.state.feeGrowthGlobalX128,
                                twPremiumX96: params.globalFundingGrowth.twPremiumX96,
                                twPremiumDivBySqrtPriceX96: params.globalFundingGrowth.twPremiumDivBySqrtPriceX96
                            })
                        );
                    }

                    int128 liquidityNet = UniswapV3Broker.getTickLiquidityNet(pool, step.nextTick);
                    if (params.isBaseToQuote) liquidityNet = -liquidityNet;
                    params.state.liquidity = LiquidityMath.addDelta(params.state.liquidity, liquidityNet);
                }

                params.state.tick = params.isBaseToQuote ? step.nextTick - 1 : step.nextTick;
            } else if (params.state.sqrtPriceX96 != step.initialSqrtPriceX96) {
                // update state.tick corresponding to the current price if the price has changed in this step
                params.state.tick = TickMath.getTickAtSqrtRatio(params.state.sqrtPriceX96);
            }
        }
        if (params.shouldUpdateState) {
            // update global states since swap state transitions are all done
            _feeGrowthGlobalX128Map[params.baseToken] = params.state.feeGrowthGlobalX128;
        }

        return
            ReplaySwapResponse({ tick: params.state.tick, fee: feeResult, insuranceFundFee: insuranceFundFeeResult });
    }

    //
    // INTERNAL VIEW
    //

    /// @dev Get total amount of the specified tokens in the specified pool.
    ///      Note:
    ///        1. when querying quote amount, it includes ClearingHouse fees, i.e.:
    ///           quote amount = quote liquidity + fees
    ///           base amount = base liquidity
    ///        2. quote/base liquidity does NOT include Uniswap pool fees since
    ///           they do not have any impact to our margin system
    function _getTotalTokenAmountInPool(
        address trader,
        address baseToken, // this argument is only for specifying which pool to get base or quote amounts
        bool fetchBase // true: fetch base amount, false: fetch quote amount
    ) internal view returns (uint256 tokenAmount) {
        bytes32[] memory orderIds = _openOrderIdsMap[trader][baseToken];

        //
        // tick:    lower             upper
        //       -|---+-----------------+---|--
        //     case 1                    case 2
        //
        // if current price < upper tick, maker has base
        // case 1 : current price < lower tick
        //  --> maker only has base token
        //
        // if current price > lower tick, maker has quote
        // case 2 : current price > upper tick
        //  --> maker only has quote token
        uint160 sqrtMarkPriceX96 = UniswapV3Broker.getSqrtMarkPriceX96(_poolMap[baseToken]);
        for (uint256 i = 0; i < orderIds.length; i++) {
            OpenOrder memory order = _openOrderMap[orderIds[i]];

            uint256 amount;
            {
                uint160 sqrtPriceAtLowerTick = TickMath.getSqrtRatioAtTick(order.lowerTick);
                uint160 sqrtPriceAtUpperTick = TickMath.getSqrtRatioAtTick(order.upperTick);
                if (fetchBase && sqrtMarkPriceX96 < sqrtPriceAtUpperTick) {
                    amount = LiquidityAmounts.getAmount0ForLiquidity(
                        sqrtMarkPriceX96 > sqrtPriceAtLowerTick ? sqrtMarkPriceX96 : sqrtPriceAtLowerTick,
                        sqrtPriceAtUpperTick,
                        order.liquidity
                    );
                } else if (!fetchBase && sqrtMarkPriceX96 > sqrtPriceAtLowerTick) {
                    amount = LiquidityAmounts.getAmount1ForLiquidity(
                        sqrtPriceAtLowerTick,
                        sqrtMarkPriceX96 < sqrtPriceAtUpperTick ? sqrtMarkPriceX96 : sqrtPriceAtUpperTick,
                        order.liquidity
                    );
                }
            }
            tokenAmount = tokenAmount.add(amount);

            if (!fetchBase) {
                // get uncollected fee (only quote)

                mapping(int24 => Tick.GrowthInfo) storage tickMap = _growthOutsideTickMap[baseToken];
                uint256 feeGrowthGlobalX128 = _feeGrowthGlobalX128Map[baseToken];
                uint256 feeGrowthInsideClearingHouseX128 =
                    tickMap.getFeeGrowthInside(
                        order.lowerTick,
                        order.upperTick,
                        TickMath.getTickAtSqrtRatio(sqrtMarkPriceX96),
                        feeGrowthGlobalX128
                    );

                tokenAmount = tokenAmount.add(
                    _calcOwedFee(
                        order.liquidity,
                        feeGrowthInsideClearingHouseX128,
                        order.feeGrowthInsideClearingHouseLastX128
                    )
                );
            }
        }
    }

    function _getLiquidityCoefficientInFundingPayment(
        OpenOrder memory order,
        Tick.FundingGrowthRangeInfo memory fundingGrowthRangeInfo
    ) internal pure returns (int256) {
        uint160 sqrtPriceX96AtUpperTick = TickMath.getSqrtRatioAtTick(order.upperTick);

        // base amount below the range
        uint256 baseAmountBelow =
            LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtRatioAtTick(order.lowerTick),
                sqrtPriceX96AtUpperTick,
                order.liquidity
            );
        int256 fundingBelowX96 =
            baseAmountBelow.toInt256().mul(
                fundingGrowthRangeInfo.twPremiumGrowthBelowX96.sub(order.lastTwPremiumGrowthBelowX96)
            );

        // funding inside the range =
        // liquidity * (ΔtwPremiumDivBySqrtPriceGrowthInsideX96 - ΔtwPremiumGrowthInsideX96 / sqrtPriceAtUpperTick)
        int256 fundingInsideX96 =
            order.liquidity.toInt256().mul(
                // ΔtwPremiumDivBySqrtPriceGrowthInsideX96
                fundingGrowthRangeInfo
                    .twPremiumDivBySqrtPriceGrowthInsideX96
                    .sub(order.lastTwPremiumDivBySqrtPriceGrowthInsideX96)
                    .sub(
                    // ΔtwPremiumGrowthInsideX96
                    (
                        fundingGrowthRangeInfo.twPremiumGrowthInsideX96.sub(order.lastTwPremiumGrowthInsideX96).mul(
                            PerpFixedPoint96.IQ96
                        )
                    )
                        .div(sqrtPriceX96AtUpperTick)
                )
            );

        return fundingBelowX96.add(fundingInsideX96).div(PerpFixedPoint96.IQ96);
    }

    function _calcOwedFee(
        uint128 liquidity,
        uint256 feeGrowthInsideNew,
        uint256 feeGrowthInsideOld
    ) internal pure returns (uint256) {
        // can NOT use safeMath, feeGrowthInside could be a very large value(a negative value)
        // which causes underflow but what we want is the difference only
        return FullMath.mulDiv(feeGrowthInsideNew - feeGrowthInsideOld, liquidity, FixedPoint128.Q128);
    }

    /// @return scaledAmountForUniswapV3PoolSwap the unsigned scaled amount for UniswapV3Pool.swap()
    /// @return signedScaledAmountForReplaySwap the signed scaled amount for _replaySwap()
    /// @dev for UniswapV3Pool.swap(), scaling the amount is necessary to achieve the custom fee effect
    /// @dev for _replaySwap(), however, as we can input ExchangeFeeRatioRatio directly in SwapMath.computeSwapStep(),
    ///      there is no need to stick to the scaled amount
    /// @dev refer to CH._openPosition() docstring for explainer diagram
    function _getScaledAmountForSwaps(
        bool isBaseToQuote,
        bool isExactInput,
        uint256 amount,
        uint24 exchangeFeeRatio,
        uint24 uniswapFeeRatio
    ) internal pure returns (uint256 scaledAmountForUniswapV3PoolSwap, int256 signedScaledAmountForReplaySwap) {
        scaledAmountForUniswapV3PoolSwap = FeeMath.calcScaledAmountForUniswapV3PoolSwap(
            isBaseToQuote,
            isExactInput,
            amount,
            exchangeFeeRatio,
            uniswapFeeRatio
        );

        // x : uniswapFeeRatio, y : exchangeFeeRatioRatio
        // since we can input ExchangeFeeRatioRatio directly in SwapMath.computeSwapStep() in _replaySwap(),
        // when !isBaseToQuote, we can use the original amount directly
        // ex: when x(uniswapFeeRatio) = 1%, y(exchangeFeeRatioRatio) = 3%, input == 1 quote
        // our target is to get fee == 0.03 quote
        // if scaling the input as 1 * 0.97 / 0.99, the fee calculated in `_replaySwap()` won't be 0.03
        signedScaledAmountForReplaySwap = isBaseToQuote
            ? scaledAmountForUniswapV3PoolSwap.toInt256()
            : amount.toInt256();
        signedScaledAmountForReplaySwap = isExactInput
            ? signedScaledAmountForReplaySwap
            : -signedScaledAmountForReplaySwap;
    }
}
