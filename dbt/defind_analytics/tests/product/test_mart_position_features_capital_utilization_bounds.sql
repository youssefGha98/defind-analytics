-- capital_utilization_current AND capital_utilization_observed must be in [0, 1].
-- Returns offending rows (violation = test failure).

SELECT token_id, capital_utilization_current, capital_utilization_observed
FROM {{ ref('mart_position_features_current') }}
WHERE
       (capital_utilization_current  IS NOT NULL
        AND (capital_utilization_current  < 0.0 OR capital_utilization_current  > 1.0))
    OR (capital_utilization_observed IS NOT NULL
        AND (capital_utilization_observed < 0.0 OR capital_utilization_observed > 1.0))
