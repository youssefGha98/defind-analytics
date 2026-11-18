SELECT
    token_id,
    start_block_number,
    start_log_index,
    count(*) AS row_count
FROM {{ ref('int_nfpm_position_liquidity_spans') }}
GROUP BY token_id, start_block_number, start_log_index
HAVING count(*) > 1
