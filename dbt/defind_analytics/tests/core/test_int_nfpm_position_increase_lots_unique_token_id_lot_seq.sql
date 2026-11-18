SELECT
    token_id,
    lot_seq,
    count() AS row_count
FROM {{ ref('int_nfpm_position_increase_lots') }}
GROUP BY token_id, lot_seq
HAVING count() > 1
