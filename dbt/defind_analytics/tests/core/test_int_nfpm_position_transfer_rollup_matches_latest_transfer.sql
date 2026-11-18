WITH latest_transfer AS (
    SELECT
        p.token_id,
        argMax(t.to_address, tuple(t.block_number, t.log_index))          AS expected_current_owner,
        argMax(t.block_number, tuple(t.block_number, t.log_index))        AS expected_block_number,
        argMax(t.block_time, tuple(t.block_number, t.log_index))          AS expected_block_time,
        argMax(t.log_index, tuple(t.block_number, t.log_index))           AS expected_log_index
    FROM {{ ref('int_nfpm_positions') }} p
    INNER JOIN {{ ref('stg_nfpm_transfers') }} t ON p.token_id = t.token_id
    GROUP BY p.token_id
)

SELECT
    r.token_id,
    r.current_owner,
    l.expected_current_owner,
    r.ownership_block_number,
    l.expected_block_number,
    r.ownership_block_time,
    l.expected_block_time,
    r.ownership_log_index,
    l.expected_log_index
FROM {{ ref('int_nfpm_position_transfer_rollup') }} r
INNER JOIN latest_transfer l ON r.token_id = l.token_id
WHERE r.current_owner != l.expected_current_owner
   OR r.ownership_block_number != l.expected_block_number
   OR r.ownership_block_time != l.expected_block_time
   OR r.ownership_log_index != l.expected_log_index
