-- Compressed tick session history — one row per period at a constant tick.
-- Minimal source for: time-in-range, per-tick volume, tick × block-span analysis.
--
-- Session = consecutive sequence of swaps where the price stayed at the same tick.
-- Multiple swaps in the same block open separate sessions if the tick moves each time.
-- Volume = sum of abs(amount1) * price_token1_in_token0 across all swaps in the session.
-- Duration = elapsed time until the first swap of the next session (when tick changes).
-- end_block / end_time / next_tick = NULL for the last session (still open).
--
-- Partitioned by pool for multi-pool support.
--
-- KEY DECISIONS :
--   - volume_token0_equiv uses abs(amount1) * price_token1_in_token0 instead of abs(amount0).
--     This is generic regardless of which token is the stablecoin or how token0/token1
--     are ordered by contract address.
--   - price_token1_in_token0 is taken directly from stg_swaps (derived from sqrtPriceX96)
--     and averaged across swaps in the session. The previous hardcoded formula
--     (1e12 / pow(1.0001, tick)) was specific to USDC/WETH (decimals 6 and 18).

WITH

swaps_ordered AS (
    SELECT
        pool,
        block_number,
        log_index,
        block_time,
        tick,
        price_token1_in_token0,
        -- volume in token0 equiv: token1 amount converted via price_token1_in_token0.
        -- Generic: works regardless of token0/token1 ordering or decimals.
        abs(toFloat64(amount1)) * toFloat64(price_token1_in_token0)              AS volume_token0_equiv,
        row_number() OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
        )                                                                        AS rn,
        -- previous tick in the same pool
        -- sentinel -999999 for the first row (outside valid Uniswap V3 range: [-887272, 887272])
        LAG(tick, 1, toInt32(-999999)) OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
        )                                                                        AS prev_tick
    FROM {{ ref('stg_swaps') }}
),

-- session_id = cumulative counter of tick changes per pool
-- increments on every swap where the tick differs from the previous one
sessions_tagged AS (
    SELECT
        pool,
        block_number,
        log_index,
        block_time,
        tick,
        price_token1_in_token0,
        volume_token0_equiv,
        sum(toUInt64(rn = 1 OR tick != prev_tick)) OVER (
            PARTITION BY pool
            ORDER BY block_number, log_index
            ROWS UNBOUNDED PRECEDING
        )                                                                        AS session_id
    FROM swaps_ordered
),

-- Aggregation: one row per session (pool × session_id × tick)
sessions AS (
    SELECT
        pool,
        session_id,
        tick,
        -- Average price across swaps in the session.
        -- Within a single tick, sqrtPriceX96 can vary slightly;
        -- avg captures the mid-session price cleanly.
        round(avg(toFloat64(price_token1_in_token0)), 2)  AS price_token1_in_token0,
        min(block_number)                                  AS start_block,
        min(block_time)                                    AS start_time,
        count()                                            AS swap_count,
        sum(volume_token0_equiv)                                    AS volume_token0_equiv
    FROM sessions_tagged
    GROUP BY pool, session_id, tick
),

-- LEAD with sentinel: default = tick itself for the last session.
-- Consecutive sessions always have different ticks (by construction),
-- so next_tick_raw = tick if and only if it is the last session (sentinel used).
sessions_lead AS (
    SELECT
        pool,
        session_id,
        tick,
        price_token1_in_token0,
        start_block,
        start_time,
        swap_count,
        volume_token0_equiv,
        -- sentinel: if next_tick_raw = tick → last session
        -- LEAD (not leadInFrame) to access rows beyond the current frame
        LEAD(tick, 1, tick) OVER (
            PARTITION BY pool ORDER BY session_id
        )                                                AS next_tick_raw,
        LEAD(start_block, 1, toUInt64(0)) OVER (
            PARTITION BY pool ORDER BY session_id
        )                                                AS end_block_raw,
        LEAD(start_time, 1, toDateTime(0)) OVER (
            PARTITION BY pool ORDER BY session_id
        )                                                AS end_time_raw
    FROM sessions
)

SELECT
    pool,
    session_id,
    tick,
    price_token1_in_token0,
    start_block,
    start_time,
    -- NULL for the last session (still open)
    if(next_tick_raw = tick, NULL, toNullable(end_block_raw))                AS end_block,
    if(next_tick_raw = tick, NULL, toNullable(end_time_raw))                 AS end_time,
    if(next_tick_raw = tick, NULL,
        dateDiff('second', start_time, end_time_raw)
    )                                                                        AS duration_seconds,
    if(next_tick_raw = tick, NULL, toNullable(next_tick_raw))               AS next_tick,
    multiIf(
        next_tick_raw = tick,   NULL,
        next_tick_raw > tick,   'up',
        next_tick_raw < tick,   'down',
                                NULL
    )                                                                        AS direction,
    swap_count,
    volume_token0_equiv

FROM sessions_lead