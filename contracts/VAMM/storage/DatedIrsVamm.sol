// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMMBase.sol";
import "../libraries/Tick.sol";
import "../libraries/Tick.sol";
import "../libraries/TickBitmap.sol";
import "../../utils/SafeCastUni.sol";
import "../../utils/SqrtPriceMath.sol";
import "../libraries/SwapMath.sol";
import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";
import { SD59x18, convert } from "@prb/math/src/SD59x18.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../libraries/VAMMBase.sol";
import "../interfaces/IVAMMBase.sol";
import "../interfaces/IVAMM.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/Oracle.sol";
import "../../interfaces/IRateOracle.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {

    UD60x18 constant ONE = UD60x18.wrap(1e18);
    UD60x18 constant ZERO = UD60x18.wrap(0);
    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    using VAMMBase for VAMMBase.FlipTicksParams;
    using VAMMBase for bool;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Oracle for Oracle.Observation[65535];

     /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32
    function _blockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @notice Emitted by the pool for increases to the number of observations that can be stored
    /// @dev observationCardinalityNext is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    /**
     * @dev Thrown when a specified vamm is not found.
     */
    error IRSVammNotFound(uint128 vammId);

    struct LPPosition { // TODO: consider moving Position and the operations affecting Positions into a separate library for readbaility
        uint128 accountId;
        /** 
        * @dev position notional amount
        */
        int128 baseAmount;
        /** 
        * @dev lower tick boundary of the position
        */
        int24 tickLower;
        /** 
        * @dev upper tick boundary of the position
        */
        int24 tickUpper;
        /** 
        * @dev fixed token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 tracker0UpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 tracker1UpdatedGrowth;
        /** 
        * @dev current Fixed Token balance of the position, 1 fixed token can be redeemed for 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 tracker0Accumulated;
        /** 
        * @dev current Variable Token Balance of the position, 1 variable token can be redeemed for underlyingPoolAPY*(annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 tracker1Accumulated;
    }

    /// @dev Mutable (or maybe one day mutable, perahps through governance) Config for this VAMM
    struct Config {
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactPhi;
        /// @dev the beta value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactBeta;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
        /// @dev the spread taken by LPs on each trade. As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        IRateOracle rateOracle;
    }

    struct Data {
        /// @inheritdoc IVAMMBase
        IVAMMBase.VAMMVars _vammVars;
        /**
         * @dev Numeric identifier for the vamm. Must be unique.
         * @dev There cannot be a vamm with id zero (See `load()`). Id zero is used as a null vamm reference.
         */
        uint256 id;
        /**
         * Note: maybe we can find a better way of identifying a market than just a simple id
         */
        uint128 marketId;
        /**
         * @dev Maps from position ID (see `getPositionId` to the properties of that position
         */
        mapping(uint256 => LPPosition) positions;
        /**
         * @dev Maps from an account address to a list of the position IDs of positions associated with that account address. Use the `positions` mapping to see full details of any given `LPPosition`.
         */
        mapping(uint128 => uint256[]) positionsInAccount;
        uint256 termEndTimestamp;
        uint128 _maxLiquidityPerTick;
        int24 _tickSpacing;
        Config config;
        uint128 _accumulator;
        int256 _tracker0GrowthGlobalX128;
        int256 _tracker1GrowthGlobalX128;
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;

        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        require(id != 0); // TODO: custom error
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint256 maturityTimestamp) internal view returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestamp == 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonNotSupported(marketId, maturityTimestamp);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function create(uint128 _marketId, uint256 _maturityTimestamp,  uint160 _sqrtPriceX96, int24 _tickSpacing, Config memory _config) internal returns (Data storage irsVamm) {
        if (_maturityTimestamp == 0) {
            revert CustomErrors.MaturityMustBeInFuture(block.timestamp, _maturityTimestamp);
        }
        uint256 id = uint256(keccak256(abi.encodePacked(_marketId, _maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.termEndTimestamp != 0) {
            revert CustomErrors.MarketAndMaturityCombinaitonAlreadyExists(_marketId, _maturityTimestamp);
        }

        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(_tickSpacing > 0 && _tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

        initialize(irsVamm, _sqrtPriceX96, _maturityTimestamp, _marketId, _tickSpacing, _config);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(Data storage self, uint160 sqrtPriceX96, uint256 _termEndTimestamp, uint128 _marketId, int24 _tickSpacing, Config memory _config) internal {
        if (sqrtPriceX96 == 0) {
            revert CustomErrors.ExpectedNonZeroSqrtPriceForInit(sqrtPriceX96);
        }
        if (self._vammVars.sqrtPriceX96 != 0) {
            revert CustomErrors.ExpectedSqrtPriceZeroBeforeInit(self._vammVars.sqrtPriceX96);
        }
        if (_termEndTimestamp <= block.timestamp) {
            revert CustomErrors.MaturityMustBeInFuture(block.timestamp, _termEndTimestamp);
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        self.marketId = _marketId;
        self.termEndTimestamp = _termEndTimestamp;
        self._tickSpacing = _tickSpacing;

        self._maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);

        (uint16 cardinality, uint16 cardinalityNext) = self.observations.initialize(_blockTimestamp());

        self._vammVars = IVAMMBase.VAMMVars({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        configure(self, _config);
    }

    /// @notice Calculates time-weighted geometric mean price based on the past `secondsAgo` seconds
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
    /// @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
    /// @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    /// @return geometricMeanPrice The geometric mean price, which might be adjusted according to input parameters. May return zero if adjustments would take the price to or below zero - e.g. when anticipated price impact is large because the order size is large.
    function twap(Data storage self, uint32 secondsAgo, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread)
        internal
        view
        returns (UD60x18 geometricMeanPrice)
    {
        int24 arithmeticMeanTick = observe(self, secondsAgo);

        // Not yet adjusted
        geometricMeanPrice = getPriceFromTick(arithmeticMeanTick);
        UD60x18 spreadImpactDelta = ZERO;
        UD60x18 priceImpactAsFraction = ZERO;

        if (adjustForSpread) {
            require(orderSize != 0); // TODO: custom error
            spreadImpactDelta = self.config.spread;
        }

        if (adjustForPriceImpact) {
            require(orderSize != 0); // TODO: custom error
            priceImpactAsFraction = self.config.priceImpactPhi.mul(convert(uint256(orderSize > 0 ? orderSize : -orderSize)).pow(self.config.priceImpactBeta));
        }

        // The projected price impact and spread of a trade will move the price up for buys, down for sells
        if (orderSize > 0) {
            geometricMeanPrice = geometricMeanPrice.add(spreadImpactDelta).mul(ONE.add(priceImpactAsFraction));
        } else {
            if (spreadImpactDelta.gte(geometricMeanPrice)) {
                // The spread is higher than the price
                return ZERO;
            }
            if (priceImpactAsFraction.gte(ONE)) {
                // The model suggests that the price will drop below zero after price impact
                return ZERO;
            }
            geometricMeanPrice = geometricMeanPrice.sub(spreadImpactDelta).mul(ONE.sub(priceImpactAsFraction));
        }

        return geometricMeanPrice;
    }

    function getPriceFromTick(int24 tick) public pure returns(UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96));
    }

    /// @notice Calculates time-weighted arithmetic mean tick
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    function observe(Data storage self, uint32 secondsAgo)
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        if (secondsAgo == 0) {
            // return the current tick if secondsAgo == 0
            arithmeticMeanTick = self._vammVars.tick;
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0;

            (int56[] memory tickCumulatives,) =
                observe(self, secondsAgos);

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));

            // Always round to negative infinity
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) arithmeticMeanTick--;
        }
    }

    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of token1 / token0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value as of each `secondsAgos` from the current block
    /// timestamp
    function observe(
        Data storage self,
        uint32[] memory secondsAgos)
        internal
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            self.observations.observe(
                _blockTimestamp(),
                secondsAgos,
                self._vammVars.tick,
                self._vammVars.observationIndex,
                0, // liquidity is untracked
                self._vammVars.observationCardinality
            );
    }

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(Data storage self, uint16 observationCardinalityNext)
        internal
    {
        self._vammVars.unlocked.lock();
        uint16 observationCardinalityNextOld =  self._vammVars.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =  self.observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
         self._vammVars.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
                self._vammVars.unlocked.unlock();

    }

    /**
     * @notice Executes a dated maker order that provides liquidity this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param requestedBaseAmount Requested amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     * @param executedBaseAmount Executed amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     */
    function executeDatedMakerOrder(
        Data storage self,
        uint128 accountId,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        internal
        returns (int256 executedBaseAmount){
        
        int24 tickLower = TickMath.getTickAtSqrtRatio(fixedRateUpper);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(fixedRateLower);

        uint256 positionId = openPosition(self, accountId, tickLower, tickUpper);

        LPPosition memory position = getRawPosition(self, positionId);

        require(position.baseAmount + requestedBaseAmount >= 0, "Burning too much"); // TODO: CustomError

        vammMint(self, accountId, tickLower, tickUpper, requestedBaseAmount);

        self.positions[positionId].baseAmount += requestedBaseAmount;
       
        return requestedBaseAmount;
    }

    /**
     * @notice It opens a position and returns positionId
     */
    function openPosition(
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    ) 
        internal
        returns (uint256){

        uint256 positionId = getPositionId(accountId, tickLower, tickUpper);

        if(self.positions[positionId].accountId != 0) {
            return positionId;
        }

        self.positions[positionId].accountId = accountId;
        self.positions[positionId].tickLower = tickLower;
        self.positions[positionId].tickUpper = tickUpper;

        self.positionsInAccount[accountId].push(positionId);

        return positionId;
    }

    function getRawPosition(
        Data storage self,
        uint256 positionId
    )
        internal
        returns (LPPosition memory) {

        // Account zero is not a valid account. (See `Account.create()`)
        require(self.positions[positionId].accountId != 0, "Missing position"); // TODO: custom error
        
        propagatePosition(self, positionId);
        return self.positions[positionId];
    }

    function propagatePosition(
        Data storage self,
        uint256 positionId
    )
        internal {

        LPPosition memory position = self.positions[positionId];

        (int256 tracker0GlobalGrowth, int256 tracker1GlobalGrowth) = 
            growthBetweenTicks(self, position.tickLower, position.tickUpper);

        int256 tracket0DeltaGrowth =
                tracker0GlobalGrowth - position.tracker0UpdatedGrowth;
        int256 tracket1DeltaGrowth =
                tracker1GlobalGrowth - position.tracker1UpdatedGrowth;

        int256 averageBase = VAMMBase.basePerTick(
            position.tickLower,
            position.tickUpper,
            position.baseAmount
        );

        self.positions[positionId].tracker0UpdatedGrowth = tracker0GlobalGrowth;
        self.positions[positionId].tracker1UpdatedGrowth = tracker1GlobalGrowth;
        self.positions[positionId].tracker0Accumulated += tracket0DeltaGrowth * averageBase;
        self.positions[positionId].tracker1Accumulated += tracket1DeltaGrowth * averageBase;
    }

    /**
     * @notice Returns the positionId that such a position would have, shoudl it exist. Does not check for existence.
     */
    function getPositionId(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    )
        public
        pure
        returns (uint256){

        return uint256(keccak256(abi.encodePacked(accountId, tickLower, tickUpper)));
    }

    function configure(
        Data storage self,
        Config memory _config) internal {

        // TODO: sanity check config - e.g. price impact calculated must never be >= 1

        self.config = _config;
    }

    /// @dev Settlment cash flow from first principles. We define baseTokens to be the tokens at some past
    // timestamp `x` when the liquidity index was 1.
    ///   Settlement = baseTokens * liquidityIndex[maturityTimestamp] + quoteTokens
    /// At any given time, cashflow can then be calcuated as:
    ///   Cashflow = notional * (variableAPY - fixedAPY) * timeFactor

    /// GETTERS & TRACKERS
    /// @dev Internal. Calculates the fixed token balance using the formula:
    ///  fixed token balance = -(baseTokens * liquidityIndex[current]) * (1 + fixedRate * timeInYearsTillMaturity)
    function _trackFixedTokens(
      Data storage self,
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper,
      uint256 termEndTimestamp
    )
        internal
        view
        returns (
            int256 trackedValue
        )
    {
        // Settlement = base * liq index(settlement) + quote
        // cashflow = notional * (variableAPY - fixed Rate) * timeFactor
        // variableAPY * timeFactor = (rate(settlment) / rate(now)) - 1
        // cashflow = notional * (rate(settlment) / rate(now) - 1 - fixedRate*timeFactor)
        // base = notional / rateNow
        // cashflow = notional * (rate(settlment) / rate(now)) - notional(1 + fixedRate*timeFactor)
        // cashflow = base*rate(settlment) - (base*RateNow)(1 + fixedRate*timeFactor)
        // These terms are tracked:
        // - base token balance = base
        // - fixed token balance = - (base*RateNow)(1 + fixedRate*timeFactor)

        // TODO: cache time factor and rateNow outside this function and pass as param to avoid recalculations
        
        UD60x18 averagePrice = getPriceFromTick(tickUpper).add(getPriceFromTick(tickLower)).div(convert(uint256(2))); // TODO: this is a good estimate across small numbers of tick boundaries, but is fundamentally not exact for nonlinear ticks. Is it good enough?
        UD60x18 timeDeltaUntilMaturity = FixedAndVariableMath.accrualFact(termEndTimestamp - block.timestamp); 
                // currentOracleValue = rateNow
        SD59x18 currentOracleValue = VAMMBase.sd59x18(self.config.rateOracle.getCurrentIndex());
        SD59x18 timeComponent = VAMMBase.sd59x18(ONE.add(averagePrice.mul(timeDeltaUntilMaturity))); // (1 + fixedRate*timeFactor)
        SD59x18 trackedValueDecimal = convert(int256(-baseAmount)).mul(currentOracleValue.mul(timeComponent));
        trackedValue = convert(trackedValueDecimal);
    }

    // TODO: return data
    function vammMint( // TODO: unlike internal functions that we expect to call from DatedIrsVammPool, this function should not be called from outside. Maybe prefix such functions with _?
        Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal {
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestamp);
        self._vammVars.unlocked.lock();

        Tick.checkTicks(tickLower, tickUpper);

        IVAMMBase.VAMMVars memory lvammVars = self._vammVars; // SLOAD for gas optimization

        bool flippedLower;
        bool flippedUpper;

        int128 averageBase = VAMMBase.basePerTick(tickLower, tickUpper, baseAmount);

        /// @dev update the ticks if necessary
        if (averageBase != 0) {

            VAMMBase.FlipTicksParams memory params;
            params.tickLower = tickLower;
            params.tickLower = tickLower;
            params.accumulatorDelta = averageBase;
            (flippedLower, flippedUpper) = params.flipTicks(
                self._ticks,
                self._tickBitmap,
                self._vammVars,
                self._tracker0GrowthGlobalX128,
                self._tracker1GrowthGlobalX128,
                self._maxLiquidityPerTick,
                self._tickSpacing
            );
        }

        // clear any tick data that is no longer needed
        if (averageBase < 0) {
            if (flippedLower) {
                self._ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self._ticks.clear(tickUpper);
            }
        }

        if (averageBase != 0) {
            if (
                (lvammVars.tick >= tickLower) && (lvammVars.tick < tickUpper)
            ) {
                // current tick is inside the passed range
                uint128 accumulatorBefore = self._accumulator; // SLOAD for gas optimization

                self._accumulator = LiquidityMath.addDelta(
                    accumulatorBefore,
                    averageBase
                );
            }
        }

        self._vammVars.unlocked.unlock();

        emit VAMMBase.Mint(msg.sender, accountId, tickLower, tickUpper, baseAmount);
    }

    function vammSwap(
        Data storage self,
        IVAMMBase.SwapParams memory params
    )
        internal
        returns (int256 tracker0Delta, int256 tracker1Delta)
    {
        VAMMBase.checkCurrentTimestampTermEndTimestampDelta(self.termEndTimestamp);

        Tick.checkTicks(params.tickLower, params.tickUpper);

        IVAMMBase.VAMMVars memory vammVarsStart = self._vammVars;

        VAMMBase.checksBeforeSwap(params, vammVarsStart, params.baseAmountSpecified > 0);

        /// @dev lock the vamm while the swap is taking place
        self._vammVars.unlocked.lock();

        uint128 accumulatorStart = self._accumulator;

        VAMMBase.SwapState memory state = VAMMBase.SwapState({
            amountSpecifiedRemaining: params.baseAmountSpecified, // base ramaining
            sqrtPriceX96: vammVarsStart.sqrtPriceX96,
            tick: vammVarsStart.tick,
            accumulator: accumulatorStart,
            tracker0GrowthGlobalX128: self._tracker0GrowthGlobalX128,
            tracker1GrowthGlobalX128: self._tracker1GrowthGlobalX128,
            tracker0DeltaCumulative: 0, // for Trader (user invoking the swap)
            tracker1DeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price (implied fixed rate) limit
        bool advanceRight = params.baseAmountSpecified > 0;
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != params.sqrtPriceLimitX96
        ) {
            VAMMBase.StepComputations memory step;

            ///// GET NEXT TICK /////

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            /// @dev if isFT (fixed taker) (moving right to left), the nextInitializedTick should be more than or equal to the current tick
            /// @dev if !isFT (variable taker) (moving left to right), the nextInitializedTick should be less than or equal to the current tick
            /// add a test for the statement that checks for the above two conditions
            (step.tickNext, step.initialized) = self._tickBitmap
                .nextInitializedTickWithinOneWord(state.tick, self._tickSpacing, !advanceRight);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (advanceRight && step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }
            if (!advanceRight && step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            // FT
            uint160 sqrtRatioTargetX96 = step.sqrtPriceNextX96 > params.sqrtPriceLimitX96
                    ? params.sqrtPriceLimitX96
                    : step.sqrtPriceNextX96;
            // VT 
            if(!advanceRight) {
                sqrtRatioTargetX96 = step.sqrtPriceNextX96 < params.sqrtPriceLimitX96
                    ? params.sqrtPriceLimitX96
                    : step.sqrtPriceNextX96;
            }


            ///// GET SWAP RESULTS /////

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            /// @dev for a Fixed Taker (isFT) if the sqrtPriceNextX96 is larger than the limit, then the target price passed into computeSwapStep is sqrtPriceLimitX96
            /// @dev for a Variable Taker (!isFT) if the sqrtPriceNextX96 is lower than the limit, then the target price passed into computeSwapStep is sqrtPriceLimitX96
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut
            ) = SwapMath.computeSwapStep(
                SwapMath.SwapStepParams({
                    sqrtRatioCurrentX96: state.sqrtPriceX96,
                    sqrtRatioTargetX96: sqrtRatioTargetX96,
                    liquidity: state.accumulator,
                    amountRemaining: state.amountSpecifiedRemaining,
                    timeToMaturityInSeconds: self.termEndTimestamp - block.timestamp
                })
            );

            ///// UPDATE TRACKERS /////

            if(advanceRight) {
                step.baseInStep -= step.amountIn.toInt256();
                // LP is a Variable Taker
                step.tracker1Delta = (step.amountIn).toInt256();
            } else {
                step.baseInStep += step.amountOut.toInt256();
                // LP is a Fixed Taker
                step.tracker1Delta -= step.amountOut.toInt256();
            }
            state.amountSpecifiedRemaining += step.baseInStep;

            if (state.accumulator > 0) {
                (
                    state.tracker1GrowthGlobalX128,
                    state.tracker0GrowthGlobalX128,
                    step.tracker0Delta // for LP
                ) = calculateUpdatedGlobalTrackerValues( 
                    self,
                    state,
                    step,
                    self.termEndTimestamp
                );

                state.tracker0DeltaCumulative -= step.tracker0Delta; // opposite sign from that of the LP's
                state.tracker1DeltaCumulative -= step.tracker1Delta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 accumulatorNet = self._ticks.cross(
                        step.tickNext,
                        state.tracker0GrowthGlobalX128,
                        state.tracker1GrowthGlobalX128
                    );

                    state.accumulator = LiquidityMath.addDelta(
                        state.accumulator,
                        advanceRight ? accumulatorNet : -accumulatorNet
                    );

                }

                state.tick = advanceRight ? step.tickNext : step.tickNext - 1;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        ///// UPDATE VAMM VARS AFTER SWAP /////
        if (state.tick != vammVarsStart.tick) {
            // update the tick in case it changed
            (uint16 observationIndex, uint16 observationCardinality) = self.observations.write(
                vammVarsStart.observationIndex,
                _blockTimestamp(),
                vammVarsStart.tick,
                0, // Liquidity not currently being tracked
                vammVarsStart.observationCardinality,
                vammVarsStart.observationCardinalityNext
            );
            (self._vammVars.sqrtPriceX96, self._vammVars.tick, self._vammVars.observationIndex, self._vammVars.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            self._vammVars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (accumulatorStart != state.accumulator) self._accumulator = state.accumulator;

        self._tracker1GrowthGlobalX128 = state.tracker1GrowthGlobalX128;
        self._tracker0GrowthGlobalX128 = state.tracker0GrowthGlobalX128;

        tracker0Delta = state.tracker0DeltaCumulative;
        tracker1Delta = state.tracker1DeltaCumulative;

        emit VAMMBase.VAMMPriceChange(self._vammVars.tick);

        emit VAMMBase.Swap(
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.baseAmountSpecified,
            params.sqrtPriceLimitX96,
            tracker0Delta,
            tracker1Delta
        );

        self._vammVars.unlocked.unlock();
    }


    function calculateUpdatedGlobalTrackerValues( // TODO: flag really-internal somehow, e.g. prefix with underscore
        Data storage self,
        VAMMBase.SwapState memory state,
        VAMMBase.StepComputations memory step,
        uint256 termEndTimestamp
    )
        internal
        view
        returns (
            int256 stateVariableTokenGrowthGlobalX128,
            int256 stateFixedTokenGrowthGlobalX128,
            int256 tracker0Delta// for LP
        )
    {
        tracker0Delta = _trackFixedTokens(
            self,
            step.baseInStep,
            state.tick,
            step.tickNext,
            termEndTimestamp
        );

        // update global trackers
        stateVariableTokenGrowthGlobalX128 = state.tracker1GrowthGlobalX128 + FullMath.mulDivSigned(step.tracker1Delta, FixedPoint128.Q128, state.accumulator);

        stateFixedTokenGrowthGlobalX128 = state.tracker0GrowthGlobalX128 + FullMath.mulDivSigned(tracker0Delta, FixedPoint128.Q128, state.accumulator);
    }

    /// @dev 
    function trackValuesBetweenTicksOutside(
        Data storage self,
        int128 basePerTick, // base per tick (after spreading notional across all ticks)
        int24 tickLower,
        int24 tickUpper
    ) internal view returns(
        int256 tracker0GrowthOutside,
        int256 tracker1GrowthOutside
    ) {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        // Example
        // User 1 mints 1,000 notional between 2-4%
        // Assume 1% - 1 tick for simplicity
        // averageBase[user_1] = 500
        // averageBasePerTick[2%] += 500
        // averageBasePerTick[4%] -= 500
        // User 2
        // mints 1,000 notional between 2-6%
        // averageBase[user_2] = 250
        // averageBasePerTick[2%] += 250
        // averageBasePerTick[6%] -= 250
        // averageBase @ 3% = 750
        // averageBase @ 5% = 250

        // current tick = 3%
        // at 1%, outside values = (-infinity, 1%)
        // at 5%, outside values = (5%, infinity)
        // outside values for tick x don't need to change until current price passes x
        // when current prices passes x, outside value "flips" to aggregateGlobalValue - outside value

        int256 base = VAMMBase.baseBetweenTicks(tickLower, tickUpper, basePerTick);

        tracker0GrowthOutside = _trackFixedTokens(self, base, tickLower, tickUpper, self.termEndTimestamp);
        tracker1GrowthOutside = base;
    }

    // @dev For a given LP posiiton, how much of it is available to trade imn each direction?
    function getAccountUnfilledBases(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        uint256 numPositions = self.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                LPPosition memory position = getRawPosition(self, self.positionsInAccount[accountId][i]);

                // Get how liquidity is currently arranged
                //  LP has 1000 base liquidity between 2% and 4% (500 per tick)
                // Qn: how much of that liquidity is avail to traders in each direction
                (int256 unfilledLongBase,, int256 unfilledShortBase,) = trackValuesBetweenTicks(
                    self,
                    position.tickLower,
                    position.tickUpper,
                    position.baseAmount
                );

                unfilledBaseLong += unfilledLongBase;
                unfilledBaseShort += unfilledShortBase;
            }
        }
    }

    // getAccountUnfilledBases
    // -> trackValuesBetweenTicks
    //    -> trackValuesBetweenTicksOutside
    //       -> trackFixedTokens 
    //       -> VAMMBase.baseBetweenTicks 

    // @dev For a given LP posiiton, how much of it is already traded and what are base and quote tokens representing those exiting trades?
    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition memory position = getRawPosition(self, self.positionsInAccount[accountId][i]); 

            baseBalancePool += position.tracker0Accumulated;
            quoteBalancePool += position.tracker1Accumulated;
        }

    }

    function trackValuesBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) internal view returns(
        int256 tracker0GrowthOutsideLeft,
        int256 tracker1GrowthOutsideLeft,
        int256 tracker0GrowthOutsideRight,
        int256 tracker1GrowthOutsideRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0, 0, 0);
        }

        int128 averageBase = VAMMBase.basePerTick(tickLower, tickUpper, baseAmount);

        // Python
        // # compute unfilled tokens to left
        // tmp_left = self.tracked_values_between_ticks_outside(
        //     average_base=average_base,
        //     tick_lower=min(tick_lower, self._current_tick),
        //     tick_upper=min(tick_upper, self._current_tick),
        // )
        // tmp_left = list(map(lambda x: -x, tmp_left))

        // # compute unfilled tokens to right
        // tmp_right = self.tracked_values_between_ticks_outside(
        //     average_base=average_base,
        //     tick_lower=max(tick_lower, self._current_tick),
        //     tick_upper=max(tick_upper, self._current_tick),
        // )

        // return tmp_left, tmp_right

        // TODO: change code below to correspond to python

        (int256 tracker0GrowthOutsideLeft_, int256 tracker1GrowthOutsideLeft_) = trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower < self._vammVars.tick ? tickLower : self._vammVars.tick,
            tickUpper < self._vammVars.tick ? tickUpper : self._vammVars.tick
        );
        tracker0GrowthOutsideLeft = -tracker0GrowthOutsideLeft_;
        tracker1GrowthOutsideLeft = -tracker1GrowthOutsideLeft_;

        (tracker0GrowthOutsideRight, tracker1GrowthOutsideRight) = trackValuesBetweenTicksOutside(
            self,
            averageBase,
            tickLower > self._vammVars.tick ? tickLower : self._vammVars.tick,
            tickUpper < self._vammVars.tick ? tickUpper : self._vammVars.tick
        );

    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 tracker0GrowthBetween,
        int256 tracker1GrowthBetween
    )
    {
        Tick.checkTicks(tickLower, tickUpper);

        int256 tracker0BelowLowerTick;
        int256 tracker1BelowLowerTick;

        if (tickLower <= self._vammVars.tick) {
            tracker0BelowLowerTick = self._ticks[tickLower].tracker0GrowthOutsideX128;
            tracker1BelowLowerTick = self._ticks[tickLower].tracker1GrowthOutsideX128;
        } else {
            tracker0BelowLowerTick = self._tracker0GrowthGlobalX128 -
                self._ticks[tickLower].tracker0GrowthOutsideX128;
            tracker1BelowLowerTick = self._tracker1GrowthGlobalX128 -
                self._ticks[tickLower].tracker1GrowthOutsideX128;
        }

        int256 tracker0AboveUpperTick;
        int256 tracker1AboveUpperTick;

        if (tickUpper > self._vammVars.tick) {
            tracker0AboveUpperTick = self._ticks[tickUpper].tracker0GrowthOutsideX128;
            tracker1AboveUpperTick = self._ticks[tickUpper].tracker1GrowthOutsideX128;
        } else {
            tracker0AboveUpperTick = self._tracker0GrowthGlobalX128 -
                self._ticks[tickUpper].tracker0GrowthOutsideX128;
            tracker1AboveUpperTick = self._tracker1GrowthGlobalX128 -
                self._ticks[tickUpper].tracker1GrowthOutsideX128;
        }

        tracker0GrowthBetween = self._tracker0GrowthGlobalX128 - tracker0BelowLowerTick - tracker0AboveUpperTick;
        tracker1GrowthBetween = self._tracker1GrowthGlobalX128 - tracker1BelowLowerTick - tracker1AboveUpperTick;

    }
}
