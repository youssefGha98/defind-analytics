-- Tracked-LP wallet recent activity feed — 1 row per (wallet, activity event).
--
-- Surfaces NFPM lifecycle events (mint, increase_liquidity, decrease_liquidity,
-- collect, transfer, burn) on indexed pools. Time-bounded to the last 90 days
-- to keep the feed practical.
--
-- V1 attribution simplification: liquidity/collect events on a tokenId are
-- attributed to the tokenId's CURRENT owner (mart_nfpm_positions_current.current_owner).
-- This is accurate when ownership is stable; for tokens that changed hands
-- mid-life, recent events still appear under the new owner. A historically-correct
-- attribution would need a per-event ownership-asof join (deferred).
--
-- Transfer/mint/burn events use the transfer's from_address (mint: to_address
-- of mint = recipient).
--
-- description is deterministic; any human-readable styling (relative time,
-- formatted addresses, action labels) is the API/frontend's job.
--
-- GRAIN         : 1 row per (token_id, block_number, log_index, activity_type)
-- DEPENDS ON    : dim_indexed_pools, mart_nfpm_positions_current,
--                 stg_nfpm_transfers, stg_nfpm_increase_liquidity,
--                 stg_nfpm_decrease_liquidity, stg_nfpm_collects,
--                 int_daily_close_dense

{{ config(materialized='table', order_by=['wallet', 'event_time']) }}

WITH

cutoff AS (
    SELECT addDays(today(), -90) AS min_date
),

indexed AS (
    SELECT pool_address
    FROM {{ ref('dim_indexed_pools') }}
    WHERE is_active = 1
),

-- token_id -> pool, current_owner (V1 attribution anchor)
token_owners AS (
    SELECT
        pos.token_id,
        pos.pool                                                           AS pool_address,
        pos.current_owner
    FROM {{ ref('mart_nfpm_positions_current') }} pos
    INNER JOIN indexed ip ON ip.pool_address = pos.pool
    WHERE pos.is_current_owner_burn_like = 0
),

-- Daily price for token0_equiv conversion at the event date.
price_by_date AS (
    SELECT pool, date, close_price
    FROM {{ ref('int_daily_close_dense') }}
),

mint_events AS (
    SELECT
        t.token_id,
        t.tx_hash,
        t.block_number,
        t.log_index,
        t.block_time                                                       AS event_time,
        t.to_address                                                       AS wallet_actor,
        'mint'                                                             AS activity_type,
        CAST(NULL AS Nullable(Float64))                                    AS amount_token0,
        concat('NFPM mint of token #', toString(t.token_id))               AS description
    FROM {{ ref('stg_nfpm_transfers') }} t
    WHERE t.from_address = '0x0000000000000000000000000000000000000000'
),

burn_events AS (
    SELECT
        t.token_id,
        t.tx_hash,
        t.block_number,
        t.log_index,
        t.block_time                                                       AS event_time,
        t.from_address                                                     AS wallet_actor,
        'burn'                                                             AS activity_type,
        CAST(NULL AS Nullable(Float64))                                    AS amount_token0,
        concat('NFT burned (token #', toString(t.token_id), ')')           AS description
    FROM {{ ref('stg_nfpm_transfers') }} t
    WHERE t.to_address = '0x0000000000000000000000000000000000000000'
),

transfer_events AS (
    SELECT
        t.token_id,
        t.tx_hash,
        t.block_number,
        t.log_index,
        t.block_time                                                       AS event_time,
        t.from_address                                                     AS wallet_actor,
        'transfer'                                                         AS activity_type,
        CAST(NULL AS Nullable(Float64))                                    AS amount_token0,
        concat('Transferred token #', toString(t.token_id))                AS description
    FROM {{ ref('stg_nfpm_transfers') }} t
    WHERE t.from_address != '0x0000000000000000000000000000000000000000'
      AND t.to_address   != '0x0000000000000000000000000000000000000000'
),

increase_events AS (
    SELECT
        i.token_id,
        i.tx_hash,
        i.block_number,
        i.log_index,
        i.block_time                                                       AS event_time,
        toOwn.current_owner                                                AS wallet_actor,
        'increase_liquidity'                                               AS activity_type,
        toFloat64(i.amount0_raw) / pow(10, toFloat64(p.token0_decimals))
            + toFloat64(i.amount1_raw) / pow(10, toFloat64(p.token1_decimals))
                * coalesce(toFloat64(pbd.close_price), 0.0)                AS amount_token0,
        concat('Increase liquidity (token #', toString(i.token_id), ')')   AS description
    FROM {{ ref('stg_nfpm_increase_liquidity') }} i
    INNER JOIN token_owners toOwn ON toOwn.token_id = i.token_id
    INNER JOIN {{ ref('stg_pools') }} p ON p.pool = toOwn.pool_address
    LEFT JOIN price_by_date pbd
        ON pbd.pool = toOwn.pool_address
        AND pbd.date = toDate(i.block_time)
),

decrease_events AS (
    SELECT
        d.token_id,
        d.tx_hash,
        d.block_number,
        d.log_index,
        d.block_time                                                       AS event_time,
        toOwn.current_owner                                                AS wallet_actor,
        'decrease_liquidity'                                               AS activity_type,
        toFloat64(d.amount0_raw) / pow(10, toFloat64(p.token0_decimals))
            + toFloat64(d.amount1_raw) / pow(10, toFloat64(p.token1_decimals))
                * coalesce(toFloat64(pbd.close_price), 0.0)                AS amount_token0,
        concat('Decrease liquidity (token #', toString(d.token_id), ')')   AS description
    FROM {{ ref('stg_nfpm_decrease_liquidity') }} d
    INNER JOIN token_owners toOwn ON toOwn.token_id = d.token_id
    INNER JOIN {{ ref('stg_pools') }} p ON p.pool = toOwn.pool_address
    LEFT JOIN price_by_date pbd
        ON pbd.pool = toOwn.pool_address
        AND pbd.date = toDate(d.block_time)
),

collect_events AS (
    SELECT
        c.token_id,
        c.tx_hash,
        c.block_number,
        c.log_index,
        c.block_time                                                       AS event_time,
        toOwn.current_owner                                                AS wallet_actor,
        'collect'                                                          AS activity_type,
        toFloat64(c.amount0_raw) / pow(10, toFloat64(p.token0_decimals))
            + toFloat64(c.amount1_raw) / pow(10, toFloat64(p.token1_decimals))
                * coalesce(toFloat64(pbd.close_price), 0.0)                AS amount_token0,
        concat('Collect fees (token #', toString(c.token_id), ')')         AS description
    FROM {{ ref('stg_nfpm_collects') }} c
    INNER JOIN token_owners toOwn ON toOwn.token_id = c.token_id
    INNER JOIN {{ ref('stg_pools') }} p ON p.pool = toOwn.pool_address
    LEFT JOIN price_by_date pbd
        ON pbd.pool = toOwn.pool_address
        AND pbd.date = toDate(c.block_time)
),

unioned AS (
    SELECT * FROM mint_events
    UNION ALL SELECT * FROM burn_events
    UNION ALL SELECT * FROM transfer_events
    UNION ALL SELECT * FROM increase_events
    UNION ALL SELECT * FROM decrease_events
    UNION ALL SELECT * FROM collect_events
)

SELECT
    u.wallet_actor                                                         AS wallet,
    u.event_time,
    u.block_number,
    u.tx_hash,
    u.token_id,
    coalesce(toOwn.pool_address, '')                                       AS pool_address,
    u.activity_type,
    u.amount_token0,
    u.description,
    'indexed_pools_only'                                                   AS coverage_scope,
    now()                                                                  AS updated_at
FROM unioned u
LEFT JOIN token_owners toOwn ON toOwn.token_id = u.token_id
WHERE u.event_time >= (SELECT min_date FROM cutoff)
  AND (toOwn.pool_address IS NOT NULL OR u.activity_type IN ('mint', 'transfer', 'burn'))
