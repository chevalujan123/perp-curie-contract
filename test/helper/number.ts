export const getMinTick = (tickSpacing: number) => Math.ceil(-887272 / tickSpacing) * tickSpacing
export const getMaxTick = (tickSpacing: number) => Math.floor(887272 / tickSpacing) * tickSpacing

// ref : https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol#L25
export const getMaxTickRange = () => 887272 * 2

// There might be dust position or open notional after reducing position or removing liquidity.
// Ignore the dust position or notional in tests, the value is according to the experience.
// IGNORABLE_DUST represents the dust in wei.
export const IGNORABLE_DUST = 500
