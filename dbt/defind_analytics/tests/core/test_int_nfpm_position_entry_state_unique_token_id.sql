SELECT
    token_id,
    count(*) AS row_count
FROM {{ ref('int_nfpm_position_entry_state') }}
GROUP BY token_id
HAVING count(*) > 1
