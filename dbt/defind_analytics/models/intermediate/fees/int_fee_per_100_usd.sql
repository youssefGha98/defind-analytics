-- Bond-equivalent LP coupon per 100 token0 deployed, by hypothetical range width.
--
-- The model is dense on (pool, date, range_width_ticks) because int_daily_close_dense
-- is the driver. Fees default to 0 on quiet days; the coupon therefore becomes 0
-- when there is active liquidity but no swap activity on that day.
--
-- All _token0 values equal USD only when token0 is a known stablecoin (e.g. USDC).
--
-- GRAIN         : 1 row per (pool, date, range_width_ticks)
-- DEPENDS ON    : int_daily_close_dense, stg_pools, int_active_liquidity_daily,
--                 int_active_tvl_daily, mart_volume_daily
-- KEY DECISIONS :
--   - All window functions moved inside coupon_base CTE to allow SELECT * at the end.
--     SELECT * workaround required: ClickHouse new analyzer loses CTE column scope
--     when macros expand to long expressions.

WITH base_days AS (
    SELECT
        dc.pool,
        dc.date,
        dc.close_tick,
        dc.close_price,
        p.tick_spacing,
        p.token0_decimals,
        p.token1_decimals,
        arrayJoin([50, 100, 200, 500, 1000, 2000]) AS range_width_ticks
    FROM {{ ref('int_daily_close_dense') }} dc
    INNER JOIN {{ ref('stg_pools') }} p ON dc.pool = p.pool
),

snapped_ranges AS (
    SELECT
        pool,
        date,
        close_tick,
        close_price,
        token0_decimals,
        token1_decimals,
        range_width_ticks,
        toInt32(
            floor((toFloat64(close_tick) - range_width_ticks / 2.0) / tick_spacing) * tick_spacing
        ) AS tick_lower,
        toInt32(
            ceil((toFloat64(close_tick) + range_width_ticks / 2.0) / tick_spacing) * tick_spacing
        ) AS tick_upper
    FROM base_days
),

-- Pure join CTE without macros — column names are unambiguous here.
joined_raw AS (
    SELECT
        sr.pool                                                           AS pool,
        sr.date                                                           AS date,
        sr.range_width_ticks                                              AS range_width_ticks,
        sr.tick_lower                                                     AS tick_lower,
        sr.tick_upper                                                     AS tick_upper,
        sr.close_price                                                    AS close_price,
        sr.close_tick                                                     AS close_tick,
        sr.token0_decimals                                                AS token0_decimals,
        sr.token1_decimals                                                AS token1_decimals,
        toFloat64(coalesce(al.active_liquidity, toInt128(0)))             AS active_liquidity,
        coalesce(at.active_tvl_token0, 0.0)                               AS active_tvl_token0,
        coalesce(vol.fees_token0_equiv, 0.0)                              AS fees_token0_equiv
    FROM snapped_ranges sr
    LEFT JOIN {{ ref('int_active_liquidity_daily') }} al ON sr.pool = al.pool AND sr.date = al.date
    LEFT JOIN {{ ref('int_active_tvl_daily') }}       at ON sr.pool = at.pool AND sr.date = at.date
    LEFT JOIN {{ ref('mart_volume_daily') }}          vol ON sr.pool = vol.pool AND sr.date = vol.date
),

-- Macro expansion in a separate CTE — isolated from the join aliases above.
joined_inputs AS (
    SELECT
        pool,
        date,
        range_width_ticks,
        tick_lower,
        tick_upper,
        close_price,
        close_tick,
        token0_decimals,
        token1_decimals,
        active_liquidity,
        active_tvl_token0,
        fees_token0_equiv,
        if(
            tick_lower < tick_upper,
            {{ amount0_from_liquidity('1.0', sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals'), sqrt_price_at_tick('tick_upper'), 'token0_decimals') }}
            + {{ amount1_from_liquidity('1.0', sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals'), sqrt_price_at_tick('tick_lower'), 'token1_decimals') }}
                * toFloat64(close_price),
            NULL
        )                                                                 AS tvl_per_unit_L
    FROM joined_raw
),

-- Reset CTE: explicit column list after macro expansion to restore scope.
joined_inputs_flat AS (
    SELECT
        pool,
        date,
        range_width_ticks,
        tick_lower,
        tick_upper,
        close_price,
        close_tick,
        token0_decimals,
        token1_decimals,
        active_liquidity,
        active_tvl_token0,
        fees_token0_equiv,
        tvl_per_unit_L
    FROM joined_inputs
),

coupon_daily AS (
    SELECT
        pool,
        date,
        range_width_ticks,
        tick_lower,
        tick_upper,
        close_price,
        close_tick,
        active_liquidity,
        active_tvl_token0,
        tvl_per_unit_L,
        if(
            active_liquidity > 0 AND tvl_per_unit_L > 0 AND tick_lower < tick_upper,
            (100.0 / tvl_per_unit_L) / active_liquidity * fees_token0_equiv,
            NULL
        ) AS fee_per_100_token0_daily
    FROM joined_inputs_flat
),

coupon_base AS (
    SELECT
        pool,
        date,
        range_width_ticks,
        tick_lower,
        tick_upper,
        close_price,
        close_tick,
        active_liquidity,
        active_tvl_token0,
        tvl_per_unit_L,
        fee_per_100_token0_daily,
        if(fee_per_100_token0_daily IS NOT NULL, fee_per_100_token0_daily * 365.0, NULL)   AS fee_per_100_token0_annual,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) * 365.0, NULL
        )                                                                                  AS fee_per_100_token0_7d,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) = 30,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) * 365.0, NULL
        )                                                                                  AS fee_per_100_token0_30d,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) = 90,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) * 365.0, NULL
        )                                                                                  AS fee_per_100_token0_90d,
        if(fee_per_100_token0_daily IS NOT NULL, fee_per_100_token0_daily * 36500.0, NULL) AS fee_bps_annual,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) * 36500.0, NULL
        )                                                                                  AS fee_bps_7d,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) = 30,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) * 36500.0, NULL
        )                                                                                  AS fee_bps_30d,
        if(
            countIf(fee_per_100_token0_daily IS NOT NULL) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) = 90,
            avg(fee_per_100_token0_daily) OVER (PARTITION BY pool, range_width_ticks ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) * 36500.0, NULL
        )                                                                                  AS fee_bps_90d
    FROM coupon_daily
)

-- SELECT * workaround: ClickHouse new analyzer loses CTE column scope when macros
-- expand to long expressions. Explicit column list fails with UNKNOWN_IDENTIFIER.
SELECT * FROM coupon_base