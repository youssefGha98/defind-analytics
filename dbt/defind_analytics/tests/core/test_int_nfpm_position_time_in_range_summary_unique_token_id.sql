SELECT
    token_id,
    count(*) AS row_count
FROM {{ ref('int_nfpm_position_time_in_range_summary') }}
GROUP BY token_id
HAVING count(*) > 1
