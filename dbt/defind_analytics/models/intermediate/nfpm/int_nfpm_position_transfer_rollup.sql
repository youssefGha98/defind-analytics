{{ config(materialized='table', order_by=['token_id']) }}

-- Consolidated transfer rollup per mapped NFPM tokenId.
--
-- GRAIN         : 1 row per token_id
-- DEPENDS ON    : int_nfpm_positions, stg_nfpm_transfers
-- KEY DECISIONS :
--   - Current owner and ownership snapshot come from the latest Transfer.
--   - Secondary-transfer lifecycle stats are computed here so downstream marts do
--     not need to rescan the transfer event stream independently.

SELECT
    p.token_id,
    argMax(t.to_address, tuple(t.block_number, t.log_index))                        AS current_owner,
    argMax(t.block_number, tuple(t.block_number, t.log_index))                      AS ownership_block_number,
    argMax(t.block_time, tuple(t.block_number, t.log_index))                        AS ownership_block_time,
    argMax(t.log_index, tuple(t.block_number, t.log_index))                         AS ownership_log_index,
    countIf(NOT t.is_mint_transfer AND NOT t.is_burn_transfer)                      AS transfer_count,
    countIf(t.is_burn_transfer)                                                     AS burn_transfer_count,
    minIf(t.block_number, NOT t.is_mint_transfer AND NOT t.is_burn_transfer)        AS first_secondary_transfer_block_number,
    minIf(t.block_time, NOT t.is_mint_transfer AND NOT t.is_burn_transfer)          AS first_secondary_transfer_block_time,
    maxIf(t.block_number, NOT t.is_mint_transfer AND NOT t.is_burn_transfer)        AS last_secondary_transfer_block_number,
    maxIf(t.block_time, NOT t.is_mint_transfer AND NOT t.is_burn_transfer)          AS last_secondary_transfer_block_time,
    minIf(t.block_number, t.is_burn_transfer)                                       AS burn_transfer_block_number,
    minIf(t.block_time, t.is_burn_transfer)                                         AS burn_transfer_block_time,
    uniqExact(t.to_address)                                                         AS distinct_to_address_count
FROM {{ ref('int_nfpm_positions') }} p
INNER JOIN {{ ref('stg_nfpm_transfers') }} t ON p.token_id = t.token_id
GROUP BY p.token_id
