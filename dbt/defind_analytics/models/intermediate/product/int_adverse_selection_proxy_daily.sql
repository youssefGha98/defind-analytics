-- Daily adverse selection cost (LVR) proxy per pool.
--
-- This is a heuristic V1 proxy for the cost LPs pay to informed/arbitrage flow.
-- It is NOT a measured LVR — it does not look at swap microstructure.
--
-- Continuous-time LVR for a constant-product-like LP with realized variance sigma^2:
--
--   dLVR/dt = (sigma_annual^2 / 8) * V_active           (Milionis-Moallemi-Roughgarden, 2022)
--
-- Therefore:
--
--   adverse_selection_cost_apr_proxy = realized_vol_annual^2 / 8
--   lvr_proxy_daily_token0           = active_tvl_token0 * realized_vol_annual^2 / (8 * 365)
--
-- realized_vol_7d / realized_vol_30d are already annualized (sqrt(365) factor inside
-- mart_price_analytics_daily), so they plug straight in.
--
-- All rows are flagged is_estimated = 1.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : mart_price_analytics_daily, int_active_tvl_daily, mart_tvl_daily
-- KEY DECISIONS :
--   - Spine = mart_tvl_daily (dense pool/day spine, includes quiet days).
--   - active_tvl_token0 left-joined and coalesced to 0 (out-of-range days yield 0 LVR).
--   - When realized_vol is NULL (warm-up window), AS proxy is NULL too (never extrapolated).
--   - Two horizons exposed (7d / 30d). Default for product layer = 7d.

{{ config(materialized='table') }}

WITH spine AS (
    SELECT
        tvl.pool                                                           AS pool,
        tvl.date                                                           AS date,
        coalesce(at.active_tvl_token0, 0.0)                                AS active_tvl_token0,
        toUInt64(coalesce(at.active_range_count, 0))                       AS active_range_count,
        price.realized_vol_7d                                              AS realized_vol_7d,
        price.realized_vol_30d                                             AS realized_vol_30d,
        price.has_swap                                                     AS has_swap
    FROM {{ ref('mart_tvl_daily') }} tvl
    LEFT JOIN {{ ref('int_active_tvl_daily') }} at
        ON  tvl.pool = at.pool
        AND tvl.date = at.date
    LEFT JOIN {{ ref('mart_price_analytics_daily') }} price
        ON  tvl.pool = price.pool
        AND tvl.date = price.date
)

SELECT
    pool,
    date,
    active_tvl_token0,
    active_range_count,
    realized_vol_7d,
    realized_vol_30d,
    has_swap,

    -- APR-form LVR proxies (unitless yield, 0.05 = 5%/yr)
    if(realized_vol_7d  IS NOT NULL, pow(realized_vol_7d,  2) / 8.0, NULL) AS adverse_selection_cost_apr_proxy_7d,
    if(realized_vol_30d IS NOT NULL, pow(realized_vol_30d, 2) / 8.0, NULL) AS adverse_selection_cost_apr_proxy_30d,

    -- Daily token0 LVR drag (= APR / 365 * active_tvl_token0)
    if(realized_vol_7d  IS NOT NULL,
       active_tvl_token0 * pow(realized_vol_7d,  2) / (8.0 * 365.0),
       NULL)                                                               AS lvr_proxy_daily_token0_7d,
    if(realized_vol_30d IS NOT NULL,
       active_tvl_token0 * pow(realized_vol_30d, 2) / (8.0 * 365.0),
       NULL)                                                               AS lvr_proxy_daily_token0_30d,

    -- Default product surface uses the 7d horizon — most reactive to regime.
    if(realized_vol_7d  IS NOT NULL, pow(realized_vol_7d,  2) / 8.0, NULL) AS adverse_selection_cost_apr_proxy,
    if(realized_vol_7d  IS NOT NULL,
       active_tvl_token0 * pow(realized_vol_7d,  2) / (8.0 * 365.0),
       NULL)                                                               AS lvr_proxy_daily_token0,

    toUInt8(1)                                                             AS is_estimated
FROM spine
