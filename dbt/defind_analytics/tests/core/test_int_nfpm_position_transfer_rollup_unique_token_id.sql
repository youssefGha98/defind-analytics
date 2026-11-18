SELECT
    token_id,
    count(*) AS n
FROM {{ ref('int_nfpm_position_transfer_rollup') }}
GROUP BY token_id
HAVING n > 1
