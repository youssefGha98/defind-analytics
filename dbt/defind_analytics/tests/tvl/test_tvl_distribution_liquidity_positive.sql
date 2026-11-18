-- All bins in the TVL distribution must have positive liquidity.
-- Returns 0 rows if OK.

SELECT tick_lower, tick_upper, liquidity
FROM {{ ref('mart_tvl_distribution') }}
WHERE liquidity <= 0
