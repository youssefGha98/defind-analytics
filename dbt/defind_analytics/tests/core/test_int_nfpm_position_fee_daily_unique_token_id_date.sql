SELECT
    token_id,
    date,
    count(*) AS n
FROM {{ ref('int_nfpm_position_fee_daily') }}
GROUP BY token_id, date
HAVING n > 1
