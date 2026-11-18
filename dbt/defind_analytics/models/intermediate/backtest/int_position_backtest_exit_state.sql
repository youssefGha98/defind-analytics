-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(query_settings={'join_algorithm': 'grace_hash'}) }}

-- Backtest scenario exit state at end-of-block semantics.
--
-- GRAIN         : 1 row per scenario_id
-- DEPENDS ON    : int_position_backtest_entry_liquidity, stg_swaps
-- KEY DECISIONS :
--   - Exit state is the last swap with block_number <= end_block.
--   - Principal end value excludes fees; accrued fees are added separately in the final mart.

WITH exit_state_raw AS (
    SELECT
        e.scenario_id                                                          AS scenario_id,
        e.pool                                                                 AS pool,
        e.start_block                                                          AS start_block,
        e.end_block                                                            AS end_block,
        e.tick_lower                                                           AS tick_lower,
        e.tick_upper                                                           AS tick_upper,
        e.capital_committed_token0                                             AS capital_committed_token0,
        e.rebalance_policy                                                     AS rebalance_policy,
        e.tick_spacing                                                         AS tick_spacing,
        e.token0_decimals                                                      AS token0_decimals,
        e.token1_decimals                                                      AS token1_decimals,
        e.start_snapshot_block_number                                          AS start_snapshot_block_number,
        e.start_snapshot_log_index                                             AS start_snapshot_log_index,
        e.start_snapshot_block_time                                            AS start_snapshot_block_time,
        e.start_tick                                                           AS start_tick,
        e.start_price                                                          AS start_price,
        e.start_sqrt_price                                                     AS start_sqrt_price,
        e.start_position_status                                                AS start_position_status,
        e.initial_liquidity                                                    AS initial_liquidity,
        e.initial_amount0                                                      AS initial_amount0,
        e.initial_amount1                                                      AS initial_amount1,
        {{ latest_swap_state_columns(
            source_alias='s',
            block_alias='end_snapshot_block_number',
            log_alias='end_snapshot_log_index',
            time_alias='end_snapshot_block_time',
            tick_alias='end_tick',
            price_alias='end_price'
        ) }}
    FROM {{ ref('int_position_backtest_entry_liquidity') }} e
    LEFT JOIN {{ ref('stg_swaps') }} s
        ON  e.pool = s.pool
        AND s.block_number <= e.end_block
    GROUP BY
        e.scenario_id,
        e.pool,
        e.start_block,
        e.end_block,
        e.tick_lower,
        e.tick_upper,
        e.capital_committed_token0,
        e.rebalance_policy,
        e.tick_spacing,
        e.token0_decimals,
        e.token1_decimals,
        e.start_snapshot_block_number,
        e.start_snapshot_log_index,
        e.start_snapshot_block_time,
        e.start_tick,
        e.start_price,
        e.start_sqrt_price,
        e.start_position_status,
        e.initial_liquidity,
        e.initial_amount0,
        e.initial_amount1
)

SELECT
    esr.scenario_id                                                        AS scenario_id,
    esr.pool                                                               AS pool,
    esr.start_block                                                        AS start_block,
    esr.end_block                                                          AS end_block,
    esr.tick_lower                                                         AS tick_lower,
    esr.tick_upper                                                         AS tick_upper,
    esr.capital_committed_token0                                           AS capital_committed_token0,
    esr.rebalance_policy                                                   AS rebalance_policy,
    esr.tick_spacing                                                       AS tick_spacing,
    esr.token0_decimals                                                    AS token0_decimals,
    esr.token1_decimals                                                    AS token1_decimals,
    esr.start_snapshot_block_number                                        AS start_snapshot_block_number,
    esr.start_snapshot_log_index                                           AS start_snapshot_log_index,
    esr.start_snapshot_block_time                                          AS start_snapshot_block_time,
    esr.start_tick                                                         AS start_tick,
    esr.start_price                                                        AS start_price,
    esr.start_sqrt_price                                                   AS start_sqrt_price,
    esr.start_position_status                                              AS start_position_status,
    esr.initial_liquidity                                                  AS initial_liquidity,
    esr.initial_amount0                                                    AS initial_amount0,
    esr.initial_amount1                                                    AS initial_amount1,
    esr.end_snapshot_block_number                                          AS end_snapshot_block_number,
    esr.end_snapshot_log_index                                             AS end_snapshot_log_index,
    esr.end_snapshot_block_time                                            AS end_snapshot_block_time,
    esr.end_tick                                                           AS end_tick,
    esr.end_price                                                          AS end_price,
    if(
        esr.end_price > 0,
        {{ sqrt_price_from_price('esr.end_price', 'esr.token0_decimals', 'esr.token1_decimals') }},
        NULL
    )                                                                       AS end_sqrt_price,
    if(esr.end_tick IS NOT NULL, {{ position_status_from_tick('esr.end_tick', 'esr.tick_lower', 'esr.tick_upper') }}, NULL) AS end_position_status,
    if(
        esr.initial_liquidity IS NOT NULL AND esr.end_price > 0,
        {{ position_amount0_at_price('esr.initial_liquidity', 'esr.end_price', 'esr.tick_lower', 'esr.tick_upper', 'esr.token0_decimals', 'esr.token1_decimals') }},
        NULL
    )                                                                       AS end_amount0,
    if(
        esr.initial_liquidity IS NOT NULL AND esr.end_price > 0,
        {{ position_amount1_at_price('esr.initial_liquidity', 'esr.end_price', 'esr.tick_lower', 'esr.tick_upper', 'esr.token0_decimals', 'esr.token1_decimals') }},
        NULL
    )                                                                       AS end_amount1,
    if(
        esr.initial_liquidity IS NOT NULL AND esr.end_price > 0,
        {{ position_value_token0_at_price('esr.initial_liquidity', 'esr.end_price', 'esr.tick_lower', 'esr.tick_upper', 'esr.token0_decimals', 'esr.token1_decimals') }},
        NULL
    )                                                                       AS end_principal_value_token0
FROM exit_state_raw esr
