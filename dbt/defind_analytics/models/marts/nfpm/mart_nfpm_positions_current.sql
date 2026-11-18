{{ config(materialized='table', order_by=['token_id']) }}

WITH base AS (
    SELECT
        p.token_id                                                           AS token_id,
        c.pool                                                               AS pool,
        p.tick_lower                                                         AS tick_lower,
        p.tick_upper                                                         AS tick_upper,
        p.tick_upper - p.tick_lower                                          AS range_width_ticks,
        p.initial_owner                                                      AS initial_owner,
        p.tx_hash                                                             AS mint_tx_hash,
        p.mint_block_number                                                  AS mint_block_number,
        p.mint_block_time                                                    AS mint_block_time,
        p.transfer_log_index                                                  AS mint_transfer_log_index,
        p.increase_log_index                                                  AS mint_increase_log_index,
        p.pool_mint_log_index                                                AS pool_mint_log_index,
        p.liquidity_delta_raw                                                 AS initial_liquidity_raw,
        p.amount0_raw                                                         AS initial_amount0_raw,
        p.amount1_raw                                                         AS initial_amount1_raw,
        p.amount0                                                             AS initial_amount0,
        p.amount1                                                             AS initial_amount1,
        p.token0_symbol                                                      AS token0_symbol,
        p.token1_symbol                                                      AS token1_symbol,
        p.token0_decimals                                                    AS token0_decimals,
        p.token1_decimals                                                    AS token1_decimals,
        p.fee_bps                                                            AS fee_bps,
        tr.current_owner                                                     AS current_owner,
        tr.ownership_block_number                                            AS ownership_block_number,
        tr.ownership_block_time                                              AS ownership_block_time,
        tr.ownership_log_index,
        tr.transfer_count                                                    AS transfer_count,
        tr.burn_transfer_count                                               AS burn_transfer_count,
        tr.first_secondary_transfer_block_number                             AS first_secondary_transfer_block_number,
        tr.first_secondary_transfer_block_time                               AS first_secondary_transfer_block_time,
        tr.last_secondary_transfer_block_number                              AS last_secondary_transfer_block_number,
        tr.last_secondary_transfer_block_time                                AS last_secondary_transfer_block_time,
        tr.burn_transfer_block_number                                        AS burn_transfer_block_number,
        tr.burn_transfer_block_time                                          AS burn_transfer_block_time,
        tr.distinct_to_address_count                                         AS distinct_to_address_count,
        tr.ownership_block_number                                             AS last_transfer_block_number,
        tr.ownership_block_time                                              AS last_transfer_block_time,
        tr.ownership_log_index                                               AS last_transfer_log_index,
        ls.liquidity_event_count                                             AS liquidity_event_count,
        ls.increase_count                                                    AS increase_count,
        ls.decrease_count                                                    AS decrease_count,
        ls.current_liquidity_raw                                             AS current_liquidity_raw,
        ls.total_increase_liquidity_raw                                      AS total_increase_liquidity_raw,
        ls.total_decrease_liquidity_raw                                      AS total_decrease_liquidity_raw,
        ls.net_amount0_raw                                                   AS net_amount0_raw,
        ls.net_amount1_raw                                                   AS net_amount1_raw,
        ls.net_amount0                                                       AS net_amount0,
        ls.net_amount1                                                       AS net_amount1,
        ls.total_deposit_amount0                                             AS total_deposit_amount0,
        ls.total_deposit_amount1                                             AS total_deposit_amount1,
        ls.total_withdraw_amount0                                            AS total_withdraw_amount0,
        ls.total_withdraw_amount1                                            AS total_withdraw_amount1,
        ls.last_liquidity_event_block_number                                 AS last_liquidity_event_block_number,
        ls.last_liquidity_event_block_time                                   AS last_liquidity_event_block_time,
        ls.last_liquidity_event_log_index,
        coalesce(cr.collect_count, 0)                                          AS collect_count,
        coalesce(cr.total_collected_amount0_raw, toDecimal256(0, 0))           AS total_collected_amount0_raw,
        coalesce(cr.total_collected_amount1_raw, toDecimal256(0, 0))           AS total_collected_amount1_raw,
        coalesce(cr.total_collected_amount0, toDecimal256(0, 18))              AS total_collected_amount0,
        coalesce(cr.total_collected_amount1, toDecimal256(0, 18))              AS total_collected_amount1,
        coalesce(cr.total_principal_collected_amount0_raw, toDecimal256(0, 0)) AS total_principal_collected_amount0_raw,
        coalesce(cr.total_principal_collected_amount1_raw, toDecimal256(0, 0)) AS total_principal_collected_amount1_raw,
        coalesce(cr.total_fees_collected_amount0_raw, toDecimal256(0, 0))      AS total_fees_collected_amount0_raw,
        coalesce(cr.total_fees_collected_amount1_raw, toDecimal256(0, 0))      AS total_fees_collected_amount1_raw,
        coalesce(cr.total_principal_collected_amount0, toDecimal256(0, 18))    AS total_principal_collected_amount0,
        coalesce(cr.total_principal_collected_amount1, toDecimal256(0, 18))    AS total_principal_collected_amount1,
        coalesce(cr.total_fees_collected_amount0, toDecimal256(0, 18))         AS total_fees_collected_amount0,
        coalesce(cr.total_fees_collected_amount1, toDecimal256(0, 18))         AS total_fees_collected_amount1,
        cr.first_collect_block_number,
        cr.first_collect_block_time,
        cr.last_collect_recipient,
        cr.last_collect_block_number,
        cr.last_collect_block_time,
        cr.last_collect_log_index,
        c.current_tick                                                       AS current_tick,
        c.price_token1_in_token0                                             AS price_token1_in_token0,
        c.sqrt_price_current                                                 AS sqrt_price_current,
        greatest(toFloat64(ls.current_liquidity_raw), 0.0)                    AS current_liquidity_for_valuation
    FROM {{ ref('int_nfpm_positions') }} p
    INNER JOIN {{ ref('int_nfpm_position_transfer_rollup') }} tr ON p.token_id = tr.token_id
    INNER JOIN {{ ref('int_nfpm_position_liquidity_summary') }} ls ON p.token_id = ls.token_id
    LEFT JOIN {{ ref('int_nfpm_position_collect_rollup') }} cr ON p.token_id = cr.token_id
    INNER JOIN {{ ref('int_current_state') }} c ON p.pool = lower(c.pool)
),

position_amounts AS (
    SELECT
        *,
        current_liquidity_raw > 0                                            AS is_open,
        current_owner = '0x0000000000000000000000000000000000000000'          AS is_nft_burned,
        lower(current_owner) IN (
            '0x0000000000000000000000000000000000000000',
            '0x000000000000000000000000000000000000dead'
        )                                                                     AS is_current_owner_burn_like,
        tick_lower <= current_tick
            AND current_tick < tick_upper
            AND current_liquidity_raw > 0                                     AS is_active,
        toFloat64(current_liquidity_raw)
            / nullIf(toFloat64(initial_liquidity_raw), 0.0)                   AS current_liquidity_share_of_initial,
        greatest(
            mint_block_time,
            ownership_block_time,
            last_liquidity_event_block_time,
            coalesce(last_collect_block_time, mint_block_time),
            last_transfer_block_time
        )                                                                     AS last_position_activity_time,
        {{ amount0_from_liquidity('current_liquidity_for_valuation', clamp_sqrt_price('sqrt_price_current', 'tick_lower', 'tick_upper'), sqrt_price_at_tick('tick_upper'), 'token0_decimals') }} AS current_position_amount0,
        {{ amount1_from_liquidity('current_liquidity_for_valuation', clamp_sqrt_price('sqrt_price_current', 'tick_lower', 'tick_upper'), sqrt_price_at_tick('tick_lower'), 'token1_decimals') }} AS current_position_amount1
    FROM base
),

valued AS (
    SELECT
        *,
        current_position_amount0
            + current_position_amount1 * toFloat64(price_token1_in_token0)    AS current_position_token0
    FROM position_amounts
)

SELECT * FROM valued
