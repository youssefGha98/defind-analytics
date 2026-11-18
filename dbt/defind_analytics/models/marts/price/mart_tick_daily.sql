-- Daily aggregate of tick sessions (from int_tick_changes).
-- Foundation for: time-in-range, per-tick volume, session density.
--
-- GRAIN         : 1 row per (pool, date, tick)
-- DEPENDS ON    : int_tick_changes
-- KEY DECISIONS :
--   - Each session is assigned to the day of its start_time. Sessions spanning
--     midnight contribute entirely to the starting day — negligible error for a
--     liquid pool (sessions are short in practice).
--   - Open sessions (duration_seconds IS NULL, last session in the dataset)
--     are excluded: their duration is unknown.
--
-- Usage — time in range for a position [tick_lower, tick_upper]:
--
--   SELECT
--       pool, date,
--       sum(time_seconds)  AS time_in_range_seconds,
--       sum(volume_token0_equiv)    AS volume_in_range_token0_equiv
--   FROM mart_tick_daily
--   WHERE tick >= tick_lower AND tick < tick_upper
--   GROUP BY pool, date

SELECT
    pool,
    toDate(start_time)  AS date,
    tick,
    sum(duration_seconds) AS time_seconds,
    sum(volume_token0_equiv)       AS volume_token0_equiv,
    sum(swap_count)       AS swap_count
FROM {{ ref('int_tick_changes') }}
WHERE duration_seconds IS NOT NULL
GROUP BY pool, toDate(start_time), tick