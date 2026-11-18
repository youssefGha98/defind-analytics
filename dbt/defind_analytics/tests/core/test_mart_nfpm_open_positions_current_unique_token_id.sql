SELECT
    token_id,
    count(*) AS row_count
FROM {{ ref('mart_nfpm_open_positions_current') }}
GROUP BY token_id
HAVING count(*) > 1

