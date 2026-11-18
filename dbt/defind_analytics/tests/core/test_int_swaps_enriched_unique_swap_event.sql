SELECT
    pool,
    block_number,
    log_index,
    count(*) AS n
FROM {{ ref('int_swaps_enriched') }}
GROUP BY pool, block_number, log_index
HAVING n > 1
