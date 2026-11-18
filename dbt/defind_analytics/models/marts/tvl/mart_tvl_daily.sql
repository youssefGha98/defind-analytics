-- Exact total TVL per pool per day, denominated in token0, token1, and token0_equiv.
--
-- Unlike a cumulative sum of LP mint/burn flows, this is an exact V3 mark-to-market
-- valuation of all open ranges at the day's close price:
--   - below range  -> all token0
--   - in range     -> token0 + token1
--   - above range  -> all token1
--
-- A dense pool/day spine is generated from all LP-event and swap dates.
-- Daily close price is then carried forward so swap-only or quiet days keep a TVL row.
-- Days before the first observed swap are excluded: there is no close price to value positions.
--
-- GRAIN         : 1 row per (pool, date)
-- DEPENDS ON    : int_lp_events, int_daily_close, stg_pools, int_range_liquidity_daily
-- KEY DECISIONS :
--   - tvl_token0_equiv = tvl_token0 + tvl_token1 * price_token1_in_token0.
--     Equals USD only when token0 is a known stablecoin (e.g. USDC).
--   - daily_close_dense is rebuilt here (not read from int_daily_close_dense) because
--     this mart only needs close_price, not close_tick or close_sqrt_price.
--   - last_value(...) IGNORE NULLS carries forward close_price on quiet days.

WITH activity_dates AS (
    SELECT
        pool,
        toDate(block_time) AS date
    FROM {{ ref('int_lp_events') }}

    UNION ALL

    SELECT
        pool,
        date
    FROM {{ ref('int_daily_close') }}
),

bounds AS (
    SELECT
        pool,
        min(date) AS min_date,
        max(date) AS max_date
    FROM activity_dates
    GROUP BY pool
),

date_spine AS (
    SELECT
        pool,
        addDays(min_date, toInt32(offset)) AS date
    FROM bounds
    ARRAY JOIN range(toUInt32(dateDiff('day', min_date, max_date) + 1)) AS offset
),

daily_close_dense AS (
    SELECT
        ds.pool,
        ds.date,
        last_value(dc.close_price) IGNORE NULLS OVER (
            PARTITION BY ds.pool
            ORDER BY ds.date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                                AS close_price
    FROM date_spine ds
    LEFT JOIN (
        SELECT
            pool,
            date,
            toNullable(close_price) AS close_price
        FROM {{ ref('int_daily_close') }}
    ) dc
        ON  ds.pool = dc.pool
        AND ds.date = dc.date
),

close_with_meta AS (
    SELECT
        dcd.pool,
        dcd.date,
        dcd.close_price,
        p.token0_decimals,
        p.token1_decimals,
        {{ sqrt_price_from_price('dcd.close_price', 'p.token0_decimals', 'p.token1_decimals') }} AS close_sqrt_price
    FROM daily_close_dense dcd
    INNER JOIN {{ ref('stg_pools') }} p ON dcd.pool = p.pool
    WHERE dcd.close_price IS NOT NULL
),

open_ranges AS (
    SELECT
        cm.pool,
        cm.date,
        cm.close_price,
        cm.close_sqrt_price,
        cm.token0_decimals,
        cm.token1_decimals,
        rl.tick_lower,
        rl.tick_upper,
        rl.net_liquidity
    FROM close_with_meta cm
    INNER JOIN {{ ref('int_range_liquidity_daily') }} rl
        ON  rl.pool = cm.pool
        AND rl.date = cm.date
),

valued_range_inputs AS (
    SELECT
        pool,
        date,
        close_price,
        net_liquidity,
        token0_decimals,
        token1_decimals,
        {{ sqrt_price_at_tick('tick_lower') }}                                          AS sp_low,
        {{ sqrt_price_at_tick('tick_upper') }}                                          AS sp_high,
        {{ clamp_sqrt_price('close_sqrt_price', 'tick_lower', 'tick_upper') }}         AS sp
    FROM open_ranges
),

valued_ranges AS (
    SELECT
        pool,
        date,
        close_price,
        {{ amount0_from_liquidity('net_liquidity', 'sp', 'sp_high', 'token0_decimals') }} AS amount0,
        {{ amount1_from_liquidity('net_liquidity', 'sp', 'sp_low',  'token1_decimals') }} AS amount1
    FROM valued_range_inputs
),

daily_totals AS (
    SELECT
        pool,
        date,
        any(close_price)  AS price_token1_in_token0,
        sum(amount0)      AS tvl_token0,
        sum(amount1)      AS tvl_token1
    FROM valued_ranges
    GROUP BY pool, date
)

SELECT
    cm.pool,
    cm.date,
    coalesce(dt.tvl_token0, 0.0)                                                       AS tvl_token0,
    coalesce(dt.tvl_token1, 0.0)                                                       AS tvl_token1,
    cm.close_price                                                                     AS price_token1_in_token0,
    -- tvl_token0_equiv: total TVL in token0. Equals USD only when token0 is a stablecoin.
    coalesce(dt.tvl_token0, 0.0)
        + coalesce(dt.tvl_token1, 0.0) * toFloat64(cm.close_price)                    AS tvl_token0_equiv
FROM close_with_meta cm
LEFT JOIN daily_totals dt
    ON  cm.pool = dt.pool
    AND cm.date = dt.date