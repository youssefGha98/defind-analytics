-- Derived entry composition and liquidity for each simulated scenario.
--
-- GRAIN         : 1 row per scenario_id
-- DEPENDS ON    : int_position_backtest_entry_state
-- KEY DECISIONS :
--   - capital_committed_token0 is the canonical input.
--   - initial_liquidity is derived from the range and entry price by first valuing
--     a unit-liquidity position, then scaling it to the committed capital.

WITH unit_position AS (
    SELECT
        scenario_id                                                          AS scenario_id,
        pool                                                                 AS pool,
        start_block                                                          AS start_block,
        end_block                                                            AS end_block,
        tick_lower                                                           AS tick_lower,
        tick_upper                                                           AS tick_upper,
        capital_committed_token0                                             AS capital_committed_token0,
        rebalance_policy                                                     AS rebalance_policy,
        tick_spacing                                                         AS tick_spacing,
        token0_decimals                                                      AS token0_decimals,
        token1_decimals                                                      AS token1_decimals,
        start_snapshot_block_number                                          AS start_snapshot_block_number,
        start_snapshot_log_index                                             AS start_snapshot_log_index,
        start_snapshot_block_time                                            AS start_snapshot_block_time,
        start_tick                                                           AS start_tick,
        start_price                                                          AS start_price,
        start_sqrt_price                                                     AS start_sqrt_price,
        {{ position_status_from_tick('start_tick', 'tick_lower', 'tick_upper') }} AS start_position_status,
        {{ position_amount0_at_price('1.0', 'start_price', 'tick_lower', 'tick_upper', 'token0_decimals', 'token1_decimals') }} AS unit_amount0,
        {{ position_amount1_at_price('1.0', 'start_price', 'tick_lower', 'tick_upper', 'token0_decimals', 'token1_decimals') }} AS unit_amount1,
        {{ position_value_token0_at_price('1.0', 'start_price', 'tick_lower', 'tick_upper', 'token0_decimals', 'token1_decimals') }} AS unit_position_value_token0
    FROM {{ ref('int_position_backtest_entry_state') }}
)

SELECT
    up.scenario_id                                                         AS scenario_id,
    up.pool                                                                AS pool,
    up.start_block                                                         AS start_block,
    up.end_block                                                           AS end_block,
    up.tick_lower                                                          AS tick_lower,
    up.tick_upper                                                          AS tick_upper,
    up.capital_committed_token0                                            AS capital_committed_token0,
    up.rebalance_policy                                                    AS rebalance_policy,
    up.tick_spacing                                                        AS tick_spacing,
    up.token0_decimals                                                     AS token0_decimals,
    up.token1_decimals                                                     AS token1_decimals,
    up.start_snapshot_block_number                                         AS start_snapshot_block_number,
    up.start_snapshot_log_index                                            AS start_snapshot_log_index,
    up.start_snapshot_block_time                                           AS start_snapshot_block_time,
    up.start_tick                                                          AS start_tick,
    up.start_price                                                         AS start_price,
    up.start_sqrt_price                                                    AS start_sqrt_price,
    up.start_position_status                                               AS start_position_status,
    up.unit_amount0                                                        AS unit_amount0,
    up.unit_amount1                                                        AS unit_amount1,
    up.unit_position_value_token0                                          AS unit_position_value_token0,
    if(up.unit_position_value_token0 > 0, up.capital_committed_token0 / up.unit_position_value_token0, NULL) AS initial_liquidity,
    if(up.unit_position_value_token0 > 0, up.capital_committed_token0 / up.unit_position_value_token0 * up.unit_amount0, NULL) AS initial_amount0,
    if(up.unit_position_value_token0 > 0, up.capital_committed_token0 / up.unit_position_value_token0 * up.unit_amount1, NULL) AS initial_amount1,
    if(up.unit_position_value_token0 > 0,
        (up.capital_committed_token0 / up.unit_position_value_token0 * up.unit_amount0)
        + (up.capital_committed_token0 / up.unit_position_value_token0 * up.unit_amount1) * up.start_price,
        NULL
    )                                                                       AS initial_principal_value_token0
FROM unit_position up
