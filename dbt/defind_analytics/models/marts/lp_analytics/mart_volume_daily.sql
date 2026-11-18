-- Daily volume and generated fees per pool.
--
-- Generated fees are exact at the swap level:
--   - token0-in swaps generate fees in token0
--   - token1-in swaps generate fees in token1
-- Token1 fees are converted to token0 using the swap's own price_token1_in_token0,
-- not a daily average. The exposed daily aggregate is therefore an exact token0
-- equivalent: fees_token0_equiv.
-- Equals USD only when token0 is a known stablecoin (e.g. USDC).
--
-- Collect events are NOT used: they represent fees withdrawn by LPs,
-- which can happen weeks after generation — not a time series.
--
-- fee_bps is stored as a percentage (0.05 = 0.05%), so fee_ratio = fee_bps / 100 = 0.0005.
--
-- Exposed volumes:
--   - volume_token0     : token0-side notional
--   - volume_token1     : token1-side notional
--   - volume_token0_equiv: exact input-side notional converted to token0 at each swap price
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : int_swaps_enriched
-- PARTITIONED BY pool for multi-pool support.

SELECT
    pool,
    toDate(block_time)                                                         AS date,
    round(sum(volume_token0), 6)                                               AS volume_token0,
    round(sum(volume_token1), 12)                                              AS volume_token1,
    round(sum(volume_token0_equiv), 6)                                         AS volume_token0_equiv,
    count()                                                                    AS swap_count,
    round(sum(fees_generated_token0), 6)                                       AS fees_token0,
    round(sum(fees_generated_token1), 12)                                      AS fees_token1,
    round(sum(fees_generated_token0_equiv), 6)                                 AS fees_token0_equiv
FROM {{ ref('int_swaps_enriched') }}
GROUP BY pool, toDate(block_time)
