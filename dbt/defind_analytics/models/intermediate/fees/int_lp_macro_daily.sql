-- Pool-level macro analytics built on the dense mart_tvl_daily spine.
-- Internal aggregator — feeds mart_pool_screener_daily. Not a frontend mart.
--
-- Sparse activity sources are left-joined and coalesced to 0 where a true
-- "no activity" day is implied. Ratios remain NULL when their denominator is 0.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : mart_tvl_daily, int_daily_close_dense, int_lp_events, stg_pools,
--                 int_range_liquidity_daily, int_active_tvl_daily, mart_volume_daily,
--                 mart_price_analytics_daily, int_fee_per_100_usd
-- KEY DECISIONS :
--   - All _usd suffixes renamed to _token0 / _token0_equiv: values are denominated
--     in token0, which equals USD only when token0 is a known stablecoin (e.g. USDC).
--   - sqrt_price_from_price receives token decimals from stg_pools joined in open_ranges.

WITH spine AS (
    SELECT
        tvl.pool,
        tvl.date,
        tvl.tvl_token0_equiv                                              AS tvl_token0_equiv,
        tvl.price_token1_in_token0                                        AS close_price,
        dense.close_tick                                                   AS observed_close_tick
    FROM {{ ref('mart_tvl_daily') }} tvl
    LEFT JOIN {{ ref('int_daily_close_dense') }} dense
        ON  tvl.pool = dense.pool
        AND tvl.date = dense.date
),

spine_with_tick AS (
    SELECT
        pool,
        date,
        tvl_token0_equiv,
        close_price,
        toInt32(
            last_value(toNullable(observed_close_tick)) IGNORE NULLS OVER (
                PARTITION BY pool
                ORDER BY date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        )                                                                 AS close_tick
    FROM spine
),

event_day_context AS (
    SELECT
        tvl.pool                                                          AS event_pool,
        tvl.date                                                          AS event_date,
        tvl.price_token1_in_token0                                        AS close_price,
        toInt32(
            last_value(toNullable(dense.close_tick)) IGNORE NULLS OVER (
                PARTITION BY tvl.pool
                ORDER BY tvl.date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        )                                                                 AS close_tick
    FROM {{ ref('mart_tvl_daily') }} tvl
    LEFT JOIN {{ ref('int_daily_close_dense') }} dense
        ON  tvl.pool = dense.pool
        AND tvl.date = dense.date
),

range_day_context AS (
    SELECT
        tvl.pool                                                          AS range_pool,
        tvl.date                                                          AS range_date,
        tvl.tvl_token0_equiv                                              AS tvl_token0_equiv,
        tvl.price_token1_in_token0                                        AS close_price,
        toInt32(
            last_value(toNullable(dense.close_tick)) IGNORE NULLS OVER (
                PARTITION BY tvl.pool
                ORDER BY tvl.date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
        )                                                                 AS close_tick
    FROM {{ ref('mart_tvl_daily') }} tvl
    LEFT JOIN {{ ref('int_daily_close_dense') }} dense
        ON  tvl.pool = dense.pool
        AND tvl.date = dense.date
),

event_values AS (
    SELECT
        c.event_pool                                                      AS pool,
        c.event_date                                                      AS date,
        e.event_type,
        e.tick_lower,
        e.tick_upper,
        -- event_token0: denominated in token0. Equals USD only when token0 is a stablecoin.
        abs(toFloat64(e.amount0)) + abs(toFloat64(e.amount1)) * toFloat64(c.close_price) AS event_token0,
        c.close_tick
    FROM {{ ref('int_lp_events') }} e
    INNER JOIN event_day_context c
        ON  e.pool            = c.event_pool
        AND toDate(e.block_time) = c.event_date
),

flow_daily AS (
    SELECT
        pool                                                              AS flow_pool,
        date                                                              AS flow_date,
        countIf(event_type = 'mint')                                      AS mint_count,
        countIf(event_type = 'burn')                                      AS burn_count,
        sumIf(event_token0, event_type = 'mint')                          AS mint_token0,
        sumIf(event_token0, event_type = 'burn')                          AS burn_token0,
        countIf(
            event_type = 'burn'
            AND isNotNull(close_tick)
            AND tick_lower <= close_tick
            AND close_tick < tick_upper
        )                                                                 AS burns_inrange_count,
        countIf(
            event_type = 'burn'
            AND (
                close_tick IS NULL
                OR close_tick < tick_lower
                OR close_tick >= tick_upper
            )
        )                                                                 AS burns_outofrange_count,
        sumIf(
            event_token0,
            event_type = 'burn'
            AND isNotNull(close_tick)
            AND tick_lower <= close_tick
            AND close_tick < tick_upper
        )                                                                 AS burns_inrange_token0,
        sumIf(
            event_token0,
            event_type = 'burn'
            AND (
                close_tick IS NULL
                OR close_tick < tick_lower
                OR close_tick >= tick_upper
            )
        )                                                                 AS burns_outofrange_token0
    FROM event_values
    GROUP BY flow_pool, flow_date
),

open_ranges AS (
    SELECT
        r.range_pool                                                      AS pool,
        r.range_date                                                      AS date,
        r.close_price,
        r.close_tick,
        r.tvl_token0_equiv,
        rl.tick_lower,
        rl.tick_upper,
        rl.net_liquidity,
        p.token0_decimals,
        p.token1_decimals,
        toUInt64(rl.net_liquidity)                                        AS weight
    FROM range_day_context r
    INNER JOIN {{ ref('int_range_liquidity_daily') }} rl
        ON  r.range_pool = rl.pool
        AND r.range_date = rl.date
    INNER JOIN {{ ref('stg_pools') }} p ON r.range_pool = p.pool
),

valued_ranges AS (
    SELECT
        pool,
        date,
        tvl_token0_equiv,
        close_tick,
        tick_lower,
        tick_upper,
        net_liquidity,
        weight,
        token0_decimals,
        token1_decimals,
        tick_upper - tick_lower                                           AS range_width_ticks,
        {{ sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals') }} AS close_sqrt_price,
        close_price,
        {{ sqrt_price_at_tick('tick_lower') }}                            AS sp_low,
        {{ sqrt_price_at_tick('tick_upper') }}                            AS sp_high,
        {{ clamp_sqrt_price(sqrt_price_from_price('close_price', 'token0_decimals', 'token1_decimals'), 'tick_lower', 'tick_upper') }} AS sp
    FROM open_ranges
),

ranked_ranges AS (
    SELECT
        pool,
        date,
        tvl_token0_equiv,
        close_tick,
        tick_lower,
        tick_upper,
        range_width_ticks,
        net_liquidity,
        weight,
        {{ amount0_from_liquidity('net_liquidity', 'sp', 'sp_high', 'token0_decimals') }}
            + {{ amount1_from_liquidity('net_liquidity', 'sp', 'sp_low', 'token1_decimals') }}
                * toFloat64(close_price)                                  AS range_tvl_token0,
        row_number() OVER (
            PARTITION BY pool, date
            ORDER BY
                {{ amount0_from_liquidity('net_liquidity', 'sp', 'sp_high', 'token0_decimals') }}
                    + {{ amount1_from_liquidity('net_liquidity', 'sp', 'sp_low', 'token1_decimals') }}
                        * toFloat64(close_price) DESC,
                tick_lower,
                tick_upper
        )                                                                 AS range_rank
    FROM valued_ranges
),

range_metrics AS (
    SELECT
        pool                                                              AS rm_pool,
        date                                                              AS rm_date,
        count()                                                           AS open_range_count,
        quantileExactWeighted(0.25)(toFloat64(range_width_ticks), weight) AS range_width_p25_ticks,
        quantileExactWeighted(0.5)(toFloat64(range_width_ticks), weight)  AS range_width_median_ticks,
        quantileExactWeighted(0.75)(toFloat64(range_width_ticks), weight) AS range_width_p75_ticks,
        if(
            any(tvl_token0_equiv) > 0,
            sumIf(range_tvl_token0, range_rank <= 10) / any(tvl_token0_equiv),
            NULL
        )                                                                 AS lp_concentration_top10_pct,
        sum(
            greatest(
                0,
                least(tick_upper, close_tick + 100) - greatest(tick_lower, close_tick - 100)
            )
        ) / 200.0                                                         AS range_overlap_density
    FROM ranked_ranges
    GROUP BY rm_pool, rm_date
),

coupon_500 AS (
    SELECT
        pool AS coupon_pool,
        date AS coupon_date,
        fee_per_100_token0_7d
    FROM {{ ref('int_fee_per_100_usd') }}
    WHERE range_width_ticks = 500
),

active_tvl_join AS (
    SELECT
        pool             AS at_pool,
        date             AS at_date,
        active_tvl_token0,
        active_range_count
    FROM {{ ref('int_active_tvl_daily') }}
),

volume_join AS (
    SELECT
        pool              AS vol_pool,
        date              AS vol_date,
        fees_token0_equiv,
        volume_token0_equiv,
        swap_count
    FROM {{ ref('mart_volume_daily') }}
),

price_join AS (
    SELECT
        pool             AS price_pool,
        date             AS price_date,
        log_return,
        realized_vol_7d,
        realized_vol_30d
    FROM {{ ref('mart_price_analytics_daily') }}
),

daily_base AS (
    SELECT
        s.pool,
        s.date,
        s.close_price,
        s.close_tick,
        s.tvl_token0_equiv,
        coalesce(at.active_tvl_token0, 0.0)                               AS active_tvl_token0,
        toUInt64(coalesce(at.active_range_count, 0))                      AS active_range_count,
        coalesce(vol.fees_token0_equiv, 0.0)                              AS fees_token0_equiv,
        coalesce(vol.volume_token0_equiv, 0.0)                            AS volume_token0_equiv,
        toUInt64(coalesce(vol.swap_count, 0))                             AS swap_count,
        price.log_return,
        price.realized_vol_7d,
        price.realized_vol_30d,
        coupon.fee_per_100_token0_7d                                          AS fee_per_100_usd_7d_500,
        toUInt64(coalesce(flow.mint_count, 0))                            AS mint_count,
        toUInt64(coalesce(flow.burn_count, 0))                            AS burn_count,
        coalesce(flow.mint_token0, 0.0)                                   AS mint_token0,
        coalesce(flow.burn_token0, 0.0)                                   AS burn_token0,
        toUInt64(coalesce(flow.burns_inrange_count, 0))                   AS burns_inrange_count,
        toUInt64(coalesce(flow.burns_outofrange_count, 0))                AS burns_outofrange_count,
        coalesce(flow.burns_inrange_token0, 0.0)                          AS burns_inrange_token0,
        coalesce(flow.burns_outofrange_token0, 0.0)                       AS burns_outofrange_token0,
        toUInt64(coalesce(rm.open_range_count, 0))                        AS open_range_count,
        rm.range_width_median_ticks,
        rm.range_width_p25_ticks,
        rm.range_width_p75_ticks,
        rm.lp_concentration_top10_pct,
        coalesce(rm.range_overlap_density, 0.0)                           AS range_overlap_density,
        if(coalesce(at.active_tvl_token0, 0.0) > 0,
            coalesce(vol.fees_token0_equiv, 0.0) * 365.0 / at.active_tvl_token0,
            NULL
        )                                                                 AS apr_daily
    FROM spine_with_tick s
    LEFT JOIN active_tvl_join at   ON s.pool = at.at_pool   AND s.date = at.at_date
    LEFT JOIN volume_join vol      ON s.pool = vol.vol_pool  AND s.date = vol.vol_date
    LEFT JOIN price_join price     ON s.pool = price.price_pool AND s.date = price.price_date
    LEFT JOIN coupon_500 coupon    ON s.pool = coupon.coupon_pool AND s.date = coupon.coupon_date
    LEFT JOIN flow_daily flow      ON s.pool = flow.flow_pool AND s.date = flow.flow_date
    LEFT JOIN range_metrics rm     ON s.pool = rm.rm_pool    AND s.date = rm.rm_date
)

SELECT
    pool,
    date,
    close_price,
    close_tick,
    tvl_token0_equiv,
    active_tvl_token0,
    active_range_count,
    fees_token0_equiv,
    volume_token0_equiv,
    swap_count,
    if(tvl_token0_equiv > 0, active_tvl_token0 / tvl_token0_equiv, NULL)          AS capital_utilization,
    if(tvl_token0_equiv > 0, volume_token0_equiv / tvl_token0_equiv, NULL)        AS volume_tvl_ratio,
    if(volume_token0_equiv > 0, active_tvl_token0 / volume_token0_equiv, NULL)    AS active_liquidity_depth,
    log_return,
    realized_vol_7d,
    realized_vol_30d,
    apr_daily,
    if(
        count(apr_daily) OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7,
        avg(apr_daily)   OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
        NULL
    )                                                                              AS apr_7d,
    if(
        count(apr_daily) OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) = 30,
        avg(apr_daily)   OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW),
        NULL
    )                                                                              AS apr_30d,
    if(
        count(apr_daily) OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) = 90,
        avg(apr_daily)   OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW),
        NULL
    )                                                                              AS apr_90d,
    if(
        realized_vol_7d IS NOT NULL
        AND realized_vol_7d > 0
        AND count(apr_daily) OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7,
        avg(apr_daily) OVER (PARTITION BY pool ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) / realized_vol_7d,
        NULL
    )                                                                              AS apr7_vol_ratio,
    if(realized_vol_7d IS NOT NULL AND realized_vol_7d > 0,
        fee_per_100_usd_7d_500 / realized_vol_7d,
        NULL
    )                                                                              AS coupon_vol_ratio_500,
    mint_count,
    burn_count,
    mint_token0,
    burn_token0,
    mint_token0 - burn_token0                                                      AS net_lp_flow_token0,
    if(tvl_token0_equiv > 0, burn_token0 / tvl_token0_equiv, NULL)                AS lp_turnover,
    burns_inrange_count,
    burns_outofrange_count,
    burns_inrange_token0,
    burns_outofrange_token0,
    if(burn_count > 0, toFloat64(burns_inrange_count) / burn_count, NULL)         AS pct_burns_inrange,
    open_range_count,
    range_width_median_ticks,
    range_width_p25_ticks,
    range_width_p75_ticks,
    lp_concentration_top10_pct,
    range_overlap_density
FROM daily_base