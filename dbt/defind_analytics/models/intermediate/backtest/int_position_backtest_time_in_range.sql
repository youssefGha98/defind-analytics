-- JOIN with mixed (equality + range) conditions is unsupported by the profile-wide
-- join_algorithm=partial_merge on ClickHouse 26; grace_hash supports it and still spills to disk.
{{ config(query_settings={'join_algorithm': 'grace_hash'}) }}

-- Observed time-in-range for simulated scenarios on the swap-state timeline.
--
-- GRAIN         : 1 row per scenario_id
-- DEPENDS ON    : int_position_backtest_entry_liquidity, int_position_backtest_exit_state, int_swaps_enriched
-- KEY DECISIONS :
--   - This uses observed swap-state intervals [swap_time, next_swap_time).
--   - It is honest about the current data boundary: without a canonical block-timestamp
--     table, quiet blocks between swaps cannot be clipped exactly to arbitrary start/end blocks.
--     The resulting metrics are therefore exposed as observed_*.

WITH scenario_windows AS (
    SELECT
        e.scenario_id                                                        AS scenario_id,
        e.pool                                                               AS pool,
        e.start_block                                                        AS start_block,
        e.end_block                                                          AS end_block,
        e.tick_lower                                                         AS tick_lower,
        e.tick_upper                                                         AS tick_upper,
        e.start_snapshot_block_time                                            AS resolved_start_time,
        x.end_snapshot_block_time                                              AS resolved_end_time
    FROM {{ ref('int_position_backtest_entry_liquidity') }} e
    INNER JOIN {{ ref('int_position_backtest_exit_state') }} x USING (scenario_id)
),

overlaps AS (
    SELECT
        w.scenario_id,
        if(
            s.block_time IS NOT NULL
            AND w.resolved_start_time IS NOT NULL
            AND w.resolved_end_time IS NOT NULL,
            greatest(
                dateDiff(
                    'second',
                    greatest(s.block_time, w.resolved_start_time),
                    least(coalesce(s.next_block_time, w.resolved_end_time), w.resolved_end_time)
                ),
                0
            ),
            0
        )                                                                     AS overlap_seconds,
        if(
            s.tick_after IS NOT NULL
            AND {{ is_range_active('s.tick_after', 'w.tick_lower', 'w.tick_upper') }},
            toUInt8(1),
            toUInt8(0)
        )                                                                     AS is_active_after_swap
    FROM scenario_windows w
    LEFT JOIN {{ ref('int_swaps_enriched') }} s
        ON  w.pool = s.pool
        AND w.resolved_start_time IS NOT NULL
        AND w.resolved_end_time IS NOT NULL
        AND s.block_time < w.resolved_end_time
        AND coalesce(s.next_block_time, w.resolved_end_time) > w.resolved_start_time
)

SELECT
    w.scenario_id,
    w.pool,
    w.start_block,
    w.end_block,
    w.resolved_start_time,
    w.resolved_end_time,
    coalesce(sumIf(o.overlap_seconds, o.is_active_after_swap = 1), 0)         AS observed_time_in_range_seconds,
    coalesce(sum(o.overlap_seconds), 0)                                        AS observed_window_seconds,
    coalesce(sum(o.overlap_seconds), 0)
        - coalesce(sumIf(o.overlap_seconds, o.is_active_after_swap = 1), 0)   AS observed_out_of_range_seconds,
    if(
        coalesce(sum(o.overlap_seconds), 0) > 0,
        coalesce(sumIf(o.overlap_seconds, o.is_active_after_swap = 1), 0) / coalesce(sum(o.overlap_seconds), 0),
        NULL
    )                                                                         AS observed_time_in_range_pct,
    if(
        coalesce(sum(o.overlap_seconds), 0) > 0,
        (
            coalesce(sum(o.overlap_seconds), 0)
            - coalesce(sumIf(o.overlap_seconds, o.is_active_after_swap = 1), 0)
        ) / coalesce(sum(o.overlap_seconds), 0),
        NULL
    )                                                                         AS observed_out_of_range_pct
FROM scenario_windows w
LEFT JOIN overlaps o ON w.scenario_id = o.scenario_id
GROUP BY
    w.scenario_id,
    w.pool,
    w.start_block,
    w.end_block,
    w.resolved_start_time,
    w.resolved_end_time
