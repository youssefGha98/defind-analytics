-- capital_utilization must be in [0, 1] when defined.
-- Returns offending rows (violation = test failure).

SELECT pool_address, date, capital_utilization
FROM {{ ref('mart_pool_screener_daily') }}
WHERE capital_utilization IS NOT NULL
  AND (capital_utilization < 0.0 OR capital_utilization > 1.0)
