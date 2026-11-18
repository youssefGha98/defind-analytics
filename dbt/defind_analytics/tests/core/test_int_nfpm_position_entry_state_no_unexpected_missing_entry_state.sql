WITH first_swap AS (
    SELECT min(block_number) AS first_swap_block
    FROM {{ ref('stg_swaps') }}
)

SELECT
    es.token_id,
    es.mint_block_number
FROM {{ ref('int_nfpm_position_entry_state') }} es
CROSS JOIN first_swap fs
WHERE es.entry_state_missing
  AND es.mint_block_number >= fs.first_swap_block
