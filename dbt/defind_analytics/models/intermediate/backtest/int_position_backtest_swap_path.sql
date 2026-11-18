-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(query_settings={'join_algorithm': 'grace_hash'}) }}

-- Swap-level fee accrual path for simulated scenarios.
--
-- GRAIN         : 1 row per (scenario_id, block_number, log_index)
-- DEPENDS ON    : int_position_backtest_entry_liquidity, int_swaps_enriched
-- KEY DECISIONS :
--   - Fees accrue only on swaps strictly after start_block and up to end_block inclusive.
--   - A position earns on a swap only when it is active before the swap.
--   - Fee share = position liquidity / active liquidity at swap time, without capping.

WITH path_base AS (
    SELECT
        s.scenario_id                                                        AS scenario_id,
        s.pool                                                               AS pool,
        s.start_block                                                        AS start_block,
        s.end_block                                                          AS end_block,
        s.tick_lower                                                         AS tick_lower,
        s.tick_upper                                                         AS tick_upper,
        s.initial_liquidity                                                  AS initial_liquidity,
        sw.block_number                                                      AS block_number,
        sw.log_index                                                         AS log_index,
        sw.block_time                                                        AS block_time,
        sw.tick_before                                                       AS tick_before,
        sw.price_before                                                      AS price_before,
        sw.tick_after                                                        AS tick_after,
        sw.price_after                                                       AS price_after,
        sw.active_liquidity_at_swap                                          AS active_liquidity_at_swap,
        sw.fees_generated_token0                                             AS fees_generated_token0,
        sw.fees_generated_token1                                             AS fees_generated_token1,
        sw.fees_generated_token0_equiv                                       AS fees_generated_token0_equiv
    FROM {{ ref('int_position_backtest_entry_liquidity') }} s
    INNER JOIN {{ ref('int_swaps_enriched') }} sw
        ON  s.pool = sw.pool
        AND sw.block_number > s.start_block
        AND sw.block_number <= s.end_block
)

SELECT
    pb.scenario_id                                                         AS scenario_id,
    pb.pool                                                                AS pool,
    pb.start_block                                                         AS start_block,
    pb.end_block                                                           AS end_block,
    pb.tick_lower                                                          AS tick_lower,
    pb.tick_upper                                                          AS tick_upper,
    pb.block_number                                                        AS block_number,
    pb.log_index                                                           AS log_index,
    pb.block_time                                                          AS block_time,
    pb.tick_before                                                         AS tick_before,
    pb.price_before                                                        AS price_before,
    pb.tick_after                                                          AS tick_after,
    pb.price_after                                                         AS price_after,
    pb.active_liquidity_at_swap                                            AS active_liquidity_at_swap,
    pb.fees_generated_token0                                               AS fees_generated_token0,
    pb.fees_generated_token1                                               AS fees_generated_token1,
    pb.fees_generated_token0_equiv                                         AS fees_generated_token0_equiv,
    pb.initial_liquidity                                                   AS initial_liquidity,
    if(
        pb.tick_before IS NOT NULL
        AND {{ is_range_active('pb.tick_before', 'pb.tick_lower', 'pb.tick_upper') }},
        toUInt8(1),
        toUInt8(0)
    )                                                                       AS is_active_before_swap,
    if(
        pb.tick_before IS NOT NULL
        AND {{ is_range_active('pb.tick_before', 'pb.tick_lower', 'pb.tick_upper') }}
        AND pb.active_liquidity_at_swap > 0,
        pb.initial_liquidity / pb.active_liquidity_at_swap,
        NULL
    )                                                                       AS position_fee_share,
    if(
        pb.tick_before IS NOT NULL
        AND {{ is_range_active('pb.tick_before', 'pb.tick_lower', 'pb.tick_upper') }}
        AND pb.active_liquidity_at_swap > 0,
        pb.fees_generated_token0 * pb.initial_liquidity / pb.active_liquidity_at_swap,
        0.0
    )                                                                       AS fees_accrued_token0,
    if(
        pb.tick_before IS NOT NULL
        AND {{ is_range_active('pb.tick_before', 'pb.tick_lower', 'pb.tick_upper') }}
        AND pb.active_liquidity_at_swap > 0,
        pb.fees_generated_token1 * pb.initial_liquidity / pb.active_liquidity_at_swap,
        0.0
    )                                                                       AS fees_accrued_token1,
    if(
        pb.tick_before IS NOT NULL
        AND {{ is_range_active('pb.tick_before', 'pb.tick_lower', 'pb.tick_upper') }}
        AND pb.active_liquidity_at_swap > 0,
        pb.fees_generated_token0_equiv * pb.initial_liquidity / pb.active_liquidity_at_swap,
        0.0
    )                                                                       AS fees_accrued_token0_equiv_generated
FROM path_base pb
