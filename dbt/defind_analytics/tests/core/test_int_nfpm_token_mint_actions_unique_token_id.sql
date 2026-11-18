SELECT
    token_id,
    count(*) AS n
FROM {{ ref('int_nfpm_token_mint_actions') }}
GROUP BY token_id
HAVING n > 1
