-- Pool TVL/liquidity distribution snapshot per tick bin — 1 row per (pool, tick_lower, tick_upper).
--
-- Wraps mart_tvl_distribution with three product-layer additions:
--   1. Trailing 7-day volume / fees flowing through each bin (from int_tick_volume_daily).
--   2. fees_per_unit_liquidity (capital-efficiency density per bin).
--   3. Indexed-pool scope.
--
-- pool_paid_volatility per bin and adverse_selection_risk_proxy per bin are V1-deferred —
-- they require liquidity-weighted sigma_evc aggregation around the bin (Phase 2).
--
-- GRAIN         : 1 row per (pool, tick_lower, tick_upper)
-- DEPENDS ON    : mart_tvl_distribution, int_tick_volume_daily, dim_indexed_pools, stg_pools
-- KEY DECISIONS :
--   - Volume/fees windowed to trailing 7 days from today() — matches
--     mart_pool_screener_daily's 7d horizon.
--   - Range-JOIN (v.tick BETWEEN bin.tick_lower AND bin.tick_upper - 1) is the
--     correct semantics here. ClickHouse handles it fine for 1 pool / few thousand
--     bins / ~7 days of tick volume.
--   - is_crowded_band_raw is exposed as the bin's pct_liquidity itself; Python
--     scoring decides what "crowded" means relative to the distribution shape.

-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(materialized='table', order_by=['pool_address', 'tick_lower'], query_settings={'join_algorithm': 'grace_hash'}) }}

WITH

indexed_pools AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

bins AS (
    SELECT
        d.pool                                                             AS pool_address,
        d.tick_lower,
        d.tick_upper,
        d.tick_mid,
        d.tick_spacing,
        d.liquidity,
        d.is_active_bin,
        d.current_tick,
        d.price_token1_in_token0,
        d.token0_symbol,
        d.token1_symbol,
        d.amount0,
        d.amount1,
        d.tvl_token0,
        d.pct_liquidity,
        d.price_lower,
        d.price_upper
    FROM {{ ref('mart_tvl_distribution') }} d
    INNER JOIN indexed_pools ip ON ip.pool_address = d.pool
),

bin_flow AS (
    SELECT
        b.pool_address,
        b.tick_lower,
        b.tick_upper,
        sum(v.volume_token0_equiv)            AS volume_7d_token0_equiv,
        sum(v.fees_generated_token0_equiv)    AS fees_7d_token0_equiv,
        sum(v.swap_count)                     AS swap_count_7d
    FROM bins b
    LEFT JOIN {{ ref('int_tick_volume_daily') }} v
        ON  v.pool = b.pool_address
        AND v.tick >= b.tick_lower
        AND v.tick <  b.tick_upper
        AND v.date >= addDays(today(), -7)
    GROUP BY b.pool_address, b.tick_lower, b.tick_upper
)

SELECT
    b.pool_address,
    b.tick_lower,
    b.tick_upper,
    b.tick_mid,
    b.price_lower,
    b.price_upper,
    b.token0_symbol,
    b.token1_symbol,
    b.tick_spacing,
    b.current_tick,
    b.price_token1_in_token0,

    b.liquidity,
    b.amount0,
    b.amount1,
    b.tvl_token0,
    b.pct_liquidity,

    coalesce(f.volume_7d_token0_equiv, 0.0)                                AS volume_7d_token0_equiv,
    coalesce(f.fees_7d_token0_equiv, 0.0)                                  AS fees_7d_token0_equiv,
    toUInt64(coalesce(f.swap_count_7d, 0))                                 AS swap_count_7d,

    if(b.liquidity > 0, coalesce(f.fees_7d_token0_equiv, 0.0) / b.liquidity, NULL) AS fees_per_unit_liquidity_7d,

    b.is_active_bin                                                        AS is_current_tick,
    b.pct_liquidity                                                        AS is_crowded_band_raw,

    -- V1 placeholders (Phase 2 will fill these).
    CAST(NULL AS Nullable(Float64))                                        AS pool_paid_volatility,
    CAST(NULL AS Nullable(Float64))                                        AS adverse_selection_risk_proxy,

    now()                                                                  AS updated_at
FROM bins b
LEFT JOIN bin_flow f
    ON  f.pool_address = b.pool_address
    AND f.tick_lower   = b.tick_lower
    AND f.tick_upper   = b.tick_upper
