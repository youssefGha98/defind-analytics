SELECT
    scenario_id,
    count(*) AS n
FROM {{ ref('mart_position_backtest_summary') }}
GROUP BY scenario_id
HAVING count(*) > 1
