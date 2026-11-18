{{ config(materialized='table', order_by=['token_id']) }}

SELECT *
FROM {{ ref('mart_nfpm_positions_current') }}
WHERE is_open

