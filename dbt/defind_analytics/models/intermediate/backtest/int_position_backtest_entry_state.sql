-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(query_settings={'join_algorithm': 'grace_hash'}) }}

-- Backtest scenario entry state at end-of-block semantics.
--
-- GRAIN         : 1 row per scenario_id
-- DEPENDS ON    : int_position_backtest_inputs, stg_swaps, stg_pools
-- KEY DECISIONS :
--   - Entry state is the last swap with block_number <= start_block.
--   - This is a swap-state snapshot: if start_block itself has no swap, the scenario
--     is anchored to the most recent observable swap state before that block.

WITH entry_state_raw AS (
    SELECT
        i.scenario_id                                                        AS scenario_id,
        i.pool                                                               AS pool,
        i.start_block                                                        AS start_block,
        i.end_block                                                          AS end_block,
        i.tick_lower                                                         AS tick_lower,
        i.tick_upper                                                         AS tick_upper,
        i.capital_committed_token0                                           AS capital_committed_token0,
        i.rebalance_policy                                                   AS rebalance_policy,
        any(p.tick_spacing)                                                 AS tick_spacing,
        any(p.token0_decimals)                                              AS token0_decimals,
        any(p.token1_decimals)                                              AS token1_decimals,
        {{ latest_swap_state_columns(
            source_alias='s',
            block_alias='start_snapshot_block_number',
            log_alias='start_snapshot_log_index',
            time_alias='start_snapshot_block_time',
            tick_alias='start_tick',
            price_alias='start_price'
        ) }}
    FROM {{ ref('int_position_backtest_inputs') }} i
    INNER JOIN {{ ref('stg_pools') }} p ON i.pool = p.pool
    LEFT JOIN {{ ref('stg_swaps') }} s
        ON  i.pool = s.pool
        AND s.block_number <= i.start_block
    GROUP BY
        i.scenario_id,
        i.pool,
        i.start_block,
        i.end_block,
        i.tick_lower,
        i.tick_upper,
        i.capital_committed_token0,
        i.rebalance_policy
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
    if(
        esr.start_price > 0,
        {{ sqrt_price_from_price('esr.start_price', 'esr.token0_decimals', 'esr.token1_decimals') }},
        NULL
    )                                                                       AS start_sqrt_price
FROM entry_state_raw esr
