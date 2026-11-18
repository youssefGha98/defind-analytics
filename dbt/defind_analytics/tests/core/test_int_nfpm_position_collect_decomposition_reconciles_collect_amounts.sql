SELECT
    token_id,
    tx_hash,
    block_number,
    log_index,
    collect_amount0_raw,
    principal_collected_amount0_raw,
    fees_collected_amount0_raw,
    collect_amount1_raw,
    principal_collected_amount1_raw,
    fees_collected_amount1_raw
FROM {{ ref('int_nfpm_position_collect_decomposition') }}
WHERE principal_collected_amount0_raw < 0
   OR principal_collected_amount1_raw < 0
   OR fees_collected_amount0_raw < 0
   OR fees_collected_amount1_raw < 0
   OR principal_collected_amount0_raw + fees_collected_amount0_raw != collect_amount0_raw
   OR principal_collected_amount1_raw + fees_collected_amount1_raw != collect_amount1_raw
