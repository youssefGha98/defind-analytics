{{ config(materialized='table', order_by=['token_id']) }}

-- Observed time-in-range summary per NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_position_time_in_range_daily
-- KEY DECISIONS :
--   - The interval splitting lives in int_nfpm_position_time_in_range_daily.
--   - This model stays as the stable 1-row-per-token contract consumed by marts.

WITH rollup AS (
    SELECT
        token_id,
        any(pool)                                                            AS pool,
        sum(observed_time_in_range_seconds)                                  AS observed_time_in_range_seconds,
        sum(observed_window_seconds)                                         AS observed_window_seconds,
        sum(observed_out_of_range_seconds)                                   AS observed_out_of_range_seconds
    FROM {{ ref('int_nfpm_position_time_in_range_daily') }}
    GROUP BY token_id
)

SELECT
    token_id,
    pool,
    observed_time_in_range_seconds,
    observed_window_seconds,
    observed_out_of_range_seconds,
    if(
        observed_window_seconds > 0,
        observed_time_in_range_seconds / observed_window_seconds,
        NULL
    )                                                                        AS observed_time_in_range_pct,
    if(
        observed_window_seconds > 0,
        observed_out_of_range_seconds / observed_window_seconds,
        NULL
    )                                                                        AS observed_out_of_range_pct
FROM rollup
