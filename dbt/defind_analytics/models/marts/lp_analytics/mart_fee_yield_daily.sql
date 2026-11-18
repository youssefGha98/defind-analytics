-- DEPRECATED: this mart will be removed once notebook 03/04 migrate to
-- mart_pool_screener_daily. New consumers must use mart_pool_screener_daily,
-- which exposes the same fee/APR/TVL fields under canonical column names:
--     tvl_total_token0      → tvl_token0_equiv
--     tvl_active_token0     → active_tvl_token0
--     tvl_outofrange_token0 → out_of_range_tvl_token0
--     fees_token0_equiv     → fees_24h_token0_equiv
--     apr                   → gross_fee_apr_daily
--
-- Materialized as a VIEW (no storage) so the deprecation has zero cost.
--
-- Daily fee yield per pool.
--
-- APR = fees_token0_equiv * 365 / active_tvl_token0
-- fees_token0_equiv comes from mart_volume_daily and is computed exactly at the swap level:
-- token0 fees stay in token0, token1 fees are converted to token0 at each swap price.
--
-- active_tvl_token0 comes from int_active_tvl_daily: exact V3 TVL for all in-range
-- positions (tick_lower <= close_tick < tick_upper). Out-of-range positions
-- contribute 0 TVL and are excluded from the APR denominator — including them
-- would dilute the APR.
--
-- All _token0 values equal USD only when token0 is a known stablecoin (e.g. USDC).
-- tvl_outofrange_token0 = tvl_total_token0 - tvl_active_token0 (remainder, for reference).
-- The mart_tvl_daily spine is the driver so days without LP events are preserved.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : mart_tvl_daily, int_active_tvl_daily, mart_volume_daily

{{ config(materialized='view') }}

SELECT
    tvl.pool                                                               AS pool,
    tvl.date                                                               AS date,

    tvl.tvl_token0_equiv                                                   AS tvl_total_token0,
    coalesce(atvl.active_tvl_token0, 0.0)                                  AS tvl_active_token0,
    tvl.tvl_token0_equiv - coalesce(atvl.active_tvl_token0, 0.0)           AS tvl_outofrange_token0,

    coalesce(vol.fees_token0_equiv, 0.0)                                   AS fees_token0_equiv,

    -- Annualized APR = daily_fees × 365 / active_tvl_token0.
    -- NULL when active TVL is 0 (avoids division by zero).
    if(coalesce(atvl.active_tvl_token0, 0.0) > 0,
        round(coalesce(vol.fees_token0_equiv, 0.0) * 365.0 / atvl.active_tvl_token0, 6),
        NULL
    )                                                                      AS apr

FROM {{ ref('mart_tvl_daily') }} tvl
LEFT JOIN {{ ref('int_active_tvl_daily') }} atvl ON tvl.pool = atvl.pool AND tvl.date = atvl.date
LEFT JOIN {{ ref('mart_volume_daily') }}    vol  ON tvl.pool = vol.pool  AND tvl.date = vol.date