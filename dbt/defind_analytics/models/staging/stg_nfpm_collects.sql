{% set staging_settings = {'storage_policy': 'r2_policy'} if target.name == 'remote' else {} %}

{{ config(
    materialized='incremental',
    order_by=['coalesce(token_id, 0)', 'coalesce(block_number, 0)', 'coalesce(log_index, 0)'],
    partition_by="toYYYYMM(coalesce(block_time, toDateTime('1970-01-01 00:00:00')))",
    settings=staging_settings
) }}

WITH source AS (
    SELECT *
    FROM {{ source('analytics', 'uniswap_nfpm_collect') }}
    {% if is_incremental() %}
    WHERE block_number > (
        SELECT coalesce(max(block_number), 0)
        FROM {{ this }}
    )
    {% endif %}
)

SELECT
    assumeNotNull(tx_hash)                                                     AS tx_hash,
    toUInt64(assumeNotNull(block_number))                                      AS block_number,
    toUInt64(assumeNotNull(log_index))                                         AS log_index,
    toDateTime(assumeNotNull(block_timestamp))                                 AS block_time,
    lower(assumeNotNull(contract))                                             AS nfpm_contract,
    lower(assumeNotNull(recipient))                                            AS recipient,
    toUInt64(assumeNotNull(tokenId))                                           AS token_id,
    toDecimal256(assumeNotNull(amount0), 0)                                    AS amount0_raw,
    toDecimal256(assumeNotNull(amount1), 0)                                    AS amount1_raw
FROM source
WHERE tx_hash IS NOT NULL
  AND tokenId IS NOT NULL
  AND amount0 IS NOT NULL
  AND amount1 IS NOT NULL
  AND block_number IS NOT NULL
  AND log_index IS NOT NULL
  AND block_timestamp IS NOT NULL
  AND contract IS NOT NULL
  AND recipient IS NOT NULL
