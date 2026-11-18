-- status_in_range must be consistent with current_tick vs (tick_lower, tick_upper).
--   in_range     <=> tick_lower <= current_tick < tick_upper
--   below_range  <=> current_tick < tick_lower
--   above_range  <=> current_tick >= tick_upper
-- Returns offending rows (violation = test failure).

SELECT
    token_id,
    current_tick,
    tick_lower,
    tick_upper,
    status_in_range
FROM {{ ref('mart_position_cards_current') }}
WHERE NOT (
       (status_in_range = 'in_range'    AND tick_lower <= current_tick AND current_tick <  tick_upper)
    OR (status_in_range = 'below_range' AND current_tick <  tick_lower)
    OR (status_in_range = 'above_range' AND current_tick >= tick_upper)
)
