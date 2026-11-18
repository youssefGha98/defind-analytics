{{ config(materialized='view') }}

-- Parametrized view: gross fee APR for an ARBITRARY tick range over an
-- ARBITRARY date window. This is the answer to "if I LP in [tick_lower,
-- tick_upper] between these two dates, what fee APR would I earn?".
--
-- WHY A PARAMETRIZED VIEW (not a normal mart):
--   The range and the window are user inputs — infinitely many combinations,
--   so nothing can be pre-materialized. A ClickHouse parametrized view computes
--   it on demand from mart_tick_liquidity_volume_daily, which holds per-tick
--   fees and per-tick TVL (both verified: per-tick fees sum exactly to pool
--   daily fees).
--
-- HOW TO QUERY (the dashboard / API calls it like a table function):
--   SELECT * FROM mart_range_apr(
--       pool        = '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
--       tick_lower  = 199987,
--       tick_upper  = 200107,
--       start_date  = '2026-03-28',
--       end_date    = '2026-04-03'
--   );
--
-- DEFINITION:
--   gross_fee_apr_pct = (Σ fees in range over window / n_days_with_data) * 365
--                       / avg(daily TVL in range)  * 100
--   It is the yield a position spanning exactly [tick_lower, tick_upper] and
--   holding a proportional share of pool liquidity at every tick would have
--   earned, on the days the range had liquidity.
--
-- CAVEATS:
--   - GROSS: fees only. Before impermanent loss, gas, and adverse selection.
--   - tick_upper is EXCLUSIVE (tick >= lower AND tick < upper), matching v3.
--   - n_days counts days the range actually had rows in the tick mart. If the
--     price left the range for whole days, those days are NOT in the denominator
--     — so this is the in-range yield, not a calendar-time-weighted yield.
--   - Date-grain only (mart_tick_liquidity_volume_daily is daily). For block
--     start/end precision the hourly mart (mart_tick_sigma_evc_hourly) would be
--     needed; not wired up here.
--
-- GRAIN         : 1 row per call (aggregated over the requested range + window)
-- DEPENDS ON    : mart_tick_liquidity_volume_daily
-- PARAMETERS    : pool:String, tick_lower:Int32, tick_upper:Int32,
--                 start_date:Date, end_date:Date

WITH per_day AS (
    SELECT
        date,
        sum(fees_generated_token0_equiv)                          AS fees_token0,
        sum(tick_tvl_token0_twap)                                 AS tvl_token0
    FROM {{ ref('mart_tick_liquidity_volume_daily') }}
    WHERE lower(pool) = lower({pool:String})
      AND date BETWEEN {start_date:Date} AND {end_date:Date}
      AND tick >= {tick_lower:Int32}
      AND tick <  {tick_upper:Int32}
    GROUP BY date
)

SELECT
    lower({pool:String})                                          AS pool,
    {tick_lower:Int32}                                            AS tick_lower,
    {tick_upper:Int32}                                            AS tick_upper,
    {start_date:Date}                                             AS start_date,
    {end_date:Date}                                               AS end_date,
    count()                                                       AS n_days,
    sum(fees_token0)                                              AS total_fees_token0,
    sum(fees_token0) / nullIf(count(), 0)                         AS mean_daily_fees_token0,
    avg(tvl_token0)                                               AS avg_tvl_token0,
    100.0 * (sum(fees_token0) / nullIf(count(), 0)) * 365.0
          / nullIf(avg(tvl_token0), 0.0)                          AS gross_fee_apr_pct
FROM per_day
