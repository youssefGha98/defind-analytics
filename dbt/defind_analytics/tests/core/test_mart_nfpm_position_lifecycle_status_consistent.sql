SELECT
    token_id,
    lifecycle_status,
    is_open,
    is_nft_burned,
    time_to_close_seconds,
    time_to_burn_seconds
FROM {{ ref('mart_nfpm_position_lifecycle') }}
WHERE (lifecycle_status = 'burned' AND NOT is_nft_burned)
   OR (lifecycle_status = 'open' AND (NOT is_open OR is_nft_burned))
   OR (lifecycle_status = 'closed_unburned' AND (is_open OR is_nft_burned))
   OR (is_open AND time_to_close_seconds IS NOT NULL)
   OR (NOT is_nft_burned AND time_to_burn_seconds IS NOT NULL)
