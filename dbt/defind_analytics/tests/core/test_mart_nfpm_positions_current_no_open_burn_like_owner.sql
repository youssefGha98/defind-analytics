SELECT
    token_id,
    current_owner,
    is_open,
    is_current_owner_burn_like
FROM {{ ref('mart_nfpm_positions_current') }}
WHERE is_open = 1
  AND is_current_owner_burn_like = 1
