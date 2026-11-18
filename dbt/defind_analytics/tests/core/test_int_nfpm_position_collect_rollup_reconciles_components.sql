SELECT
    token_id,
    collect_count,
    collect_event_count,
    total_collected_amount0_raw,
    total_principal_collected_amount0_raw,
    total_fees_collected_amount0_raw,
    total_collected_amount1_raw,
    total_principal_collected_amount1_raw,
    total_fees_collected_amount1_raw,
    total_collected_amount0,
    total_principal_collected_amount0,
    total_fees_collected_amount0,
    total_collected_amount1,
    total_principal_collected_amount1,
    total_fees_collected_amount1
FROM {{ ref('int_nfpm_position_collect_rollup') }}
WHERE collect_count != collect_event_count
   OR total_collected_amount0_raw != total_principal_collected_amount0_raw + total_fees_collected_amount0_raw
   OR total_collected_amount1_raw != total_principal_collected_amount1_raw + total_fees_collected_amount1_raw
   OR abs(total_collected_amount0 - total_principal_collected_amount0 - total_fees_collected_amount0) > 1e-12
   OR abs(total_collected_amount1 - total_principal_collected_amount1 - total_fees_collected_amount1) > 1e-12
