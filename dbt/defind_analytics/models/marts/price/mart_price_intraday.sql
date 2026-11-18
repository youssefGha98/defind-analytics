-- Hourly OHLCV price mart per pool.
--
-- realized_vol_intraday is the within-day standard deviation of hourly log returns.
-- It is repeated on each hourly row of the day to simplify downstream dashboard queries.
--
-- GRAIN         : 1 row per (pool, date, hour)
-- DEPENDS ON    : stg_swaps
-- KEY DECISIONS :
--   - volume_token0_equiv = token0_in + token1_in * price_token1_in_token0.
--     Equals USD only when token0 is a known stablecoin (e.g. USDC).
--   - open/close tick and price use two separate argMin/argMax calls instead of
--     tuple-based access (tupleElement) — field access by position is fragile.

WITH hourly_bars AS (
    SELECT
        pool,
        toDate(block_time)                                                      AS date,
        toStartOfHour(block_time)                                               AS hour,
        argMin(toInt32(tick),                    tuple(block_number, log_index)) AS open_tick,
        argMin(toFloat64(price_token1_in_token0), tuple(block_number, log_index)) AS open_price,
        argMax(toInt32(tick),                    tuple(block_number, log_index)) AS close_tick,
        argMax(toFloat64(price_token1_in_token0), tuple(block_number, log_index)) AS close_price,
        min(toFloat64(price_token1_in_token0))                                  AS low_price,
        max(toFloat64(price_token1_in_token0))                                  AS high_price,
        sum(abs(toFloat64(amount0)))                                             AS volume_token0,
        sum(abs(toFloat64(amount1)))                                             AS volume_token1,
        -- Input-side notional in token0: token0_in + token1_in converted at swap price.
        sum(
            greatest(toFloat64(amount0), 0.0)
            + greatest(toFloat64(amount1), 0.0) * toFloat64(price_token1_in_token0)
        )                                                                        AS volume_token0_equiv,
        count()                                                                  AS swap_count
    FROM {{ ref('stg_swaps') }}
    GROUP BY pool, toDate(block_time), toStartOfHour(block_time)
),

hourly_returns AS (
    SELECT
        pool,
        date,
        hour,
        open_tick,
        close_tick,
        open_price,
        high_price,
        low_price,
        close_price,
        volume_token0,
        volume_token1,
        volume_token0_equiv,
        swap_count,
        lagInFrame(toNullable(close_price), 1, CAST(NULL AS Nullable(Float64))) OVER (
            PARTITION BY pool, date
            ORDER BY hour
        )                                                                        AS prev_close_price
    FROM hourly_bars
),

intraday_vol AS (
    SELECT
        pool,
        date,
        hour,
        open_tick,
        close_tick,
        open_price,
        high_price,
        low_price,
        close_price,
        volume_token0,
        volume_token1,
        volume_token0_equiv,
        swap_count,
        if(prev_close_price > 0, log(close_price / prev_close_price), NULL) AS log_return_hourly
    FROM hourly_returns
)

SELECT
    pool,
    date,
    hour,
    open_tick,
    close_tick,
    open_price,
    high_price,
    low_price,
    close_price,
    volume_token0,
    volume_token1,
    volume_token0_equiv,
    swap_count,
    log_return_hourly,
    if(
        count(log_return_hourly) OVER (PARTITION BY pool, date) >= 2,
        stddevSamp(log_return_hourly) OVER (PARTITION BY pool, date),
        NULL
    )                                                                        AS realized_vol_intraday
FROM intraday_vol