-- in_range_probability_*_observed must be in [0, 1] when defined.
-- Returns offending rows (violation = test failure).

SELECT pool_address, date, candidate_id,
       in_range_probability_7d_observed,
       in_range_probability_30d_observed
FROM {{ ref('mart_range_candidates_features') }}
WHERE
       (in_range_probability_7d_observed  IS NOT NULL
        AND (in_range_probability_7d_observed  < 0.0 OR in_range_probability_7d_observed  > 1.0))
    OR (in_range_probability_30d_observed IS NOT NULL
        AND (in_range_probability_30d_observed < 0.0 OR in_range_probability_30d_observed > 1.0))
