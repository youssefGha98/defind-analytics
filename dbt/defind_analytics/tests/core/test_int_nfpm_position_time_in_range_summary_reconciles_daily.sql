WITH daily_rollup AS (
    SELECT
        token_id,
        sum(observed_time_in_range_seconds) AS expected_time_in_range_seconds,
        sum(observed_window_seconds)        AS expected_window_seconds,
        sum(observed_out_of_range_seconds)  AS expected_out_of_range_seconds
    FROM {{ ref('int_nfpm_position_time_in_range_daily') }}
    GROUP BY token_id
)

SELECT
    s.token_id,
    s.observed_time_in_range_seconds,
    d.expected_time_in_range_seconds,
    s.observed_window_seconds,
    d.expected_window_seconds,
    s.observed_out_of_range_seconds,
    d.expected_out_of_range_seconds,
    s.observed_time_in_range_pct,
    s.observed_out_of_range_pct
FROM {{ ref('int_nfpm_position_time_in_range_summary') }} s
INNER JOIN daily_rollup d ON s.token_id = d.token_id
WHERE s.observed_time_in_range_seconds != d.expected_time_in_range_seconds
   OR s.observed_window_seconds != d.expected_window_seconds
   OR s.observed_out_of_range_seconds != d.expected_out_of_range_seconds
   OR s.observed_time_in_range_seconds + s.observed_out_of_range_seconds != s.observed_window_seconds
   OR (
        s.observed_window_seconds > 0
        AND abs(s.observed_time_in_range_pct + s.observed_out_of_range_pct - 1.0) > 1e-12
      )
