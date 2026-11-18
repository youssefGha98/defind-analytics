-- Daily price analytics per pool, derived from a dense daily close helper.
--
-- GRAIN         : 1 row per (pool, date) — contiguous, no gaps
-- DEPENDS ON    : int_daily_close_dense
-- KEY DECISIONS :
--   - realized_vol_7d / realized_vol_30d are annualized rolling standard deviations
--     of daily log returns over trailing 7 / 30 calendar-day windows.
--     Annualization factor: sqrt(365).
--   - Rolling vol is only computed when the full window is available
--     (dense_row_count_7d = 7 / dense_row_count_30d = 30) to avoid
--     understated early values from partial windows.
--   - greatest(..., 0) guards against floating-point rounding producing
--     negative variance before the sqrt.
--   - drawdown = close_price / rolling_high - 1, expressed as a negative percentage
--     from the running all-time high.
--   - has_swap is passed through from int_daily_close_dense to let consumers
--     distinguish real price observations from carry-forward days.

WITH daily_close AS (
    SELECT
        pool,
        date,
        close_tick,
        toFloat64(close_price) AS close_price,
        has_swap
    FROM {{ ref('int_daily_close_dense') }}
),

price_levels AS (
    SELECT
        pool,
        date,
        close_tick,
        close_price,
        has_swap,
        lagInFrame(close_price, 1, CAST(NULL AS Nullable(Float64))) OVER (
            PARTITION BY pool
            ORDER BY date
        )                                                               AS prev_close_price,
        count() OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        )                                                               AS dense_row_count_7d,
        count() OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        )                                                               AS dense_row_count_30d,
        max(close_price) OVER (
            PARTITION BY pool
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                                               AS rolling_high
    FROM daily_close
),

daily_returns AS (
    SELECT
        pool,
        date,
        close_tick,
        close_price,
        has_swap,
        dense_row_count_7d,
        dense_row_count_30d,
        rolling_high,
        if(
            prev_close_price > 0,
            log(close_price / prev_close_price),
            NULL
        )                                                               AS log_return
    FROM price_levels
)

SELECT
    pool,
    date,
    close_tick,
    close_price,
    has_swap,
    log_return,
    if(
        dense_row_count_7d = 7,
        sqrt(greatest(
            avg(pow(log_return, 2)) OVER (
                PARTITION BY pool
                ORDER BY date
                ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
            )
            - pow(
                avg(log_return) OVER (
                    PARTITION BY pool
                    ORDER BY date
                    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
                ),
                2
            ),
            0.0
        )) * sqrt(365.0),
        NULL
    )                                                                   AS realized_vol_7d,
    if(
        dense_row_count_30d = 30,
        sqrt(greatest(
            avg(pow(log_return, 2)) OVER (
                PARTITION BY pool
                ORDER BY date
                ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
            )
            - pow(
                avg(log_return) OVER (
                    PARTITION BY pool
                    ORDER BY date
                    ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
                ),
                2
            ),
            0.0
        )) * sqrt(365.0),
        NULL
    )                                                                   AS realized_vol_30d,
    rolling_high,
    if(rolling_high > 0, close_price / rolling_high - 1.0, NULL)        AS drawdown
FROM daily_returns