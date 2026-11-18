-- exposure_pct must be in [0, 1] when defined.
-- Returns offending rows (violation = test failure).

SELECT wallet, exposure_dimension, exposure_name, exposure_pct
FROM {{ ref('mart_tracked_lp_wallet_exposure_current') }}
WHERE exposure_pct IS NOT NULL
  AND (exposure_pct < 0.0 OR exposure_pct > 1.0 + 1e-9)
