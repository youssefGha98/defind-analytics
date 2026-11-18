from __future__ import annotations

import math

import pytest

from core.position_math import (
    amount0_from_liquidity,
    amount1_from_liquidity,
    compute_hodl_value_in_token1,
    compute_il,
    compute_liquidity_from_amounts,
    compute_lvr_single_swap,
    compute_position_value_in_token1,
    compute_reserves,
    is_in_range,
    price_to_tick,
    sqrt_price_from_human_price,
    sqrt_price_x96_to_float,
    sqrt_price_x96_to_price,
    tick_to_price,
    tick_to_sqrt_price,
    tick_to_sqrt_price_x96,
)


def test_tick_and_sqrt_price_round_trip_is_stable() -> None:
    tick = 196_500
    sqrt_x96 = tick_to_sqrt_price_x96(tick)
    sqrt_price = sqrt_price_x96_to_float(sqrt_x96)
    price = sqrt_price_x96_to_price(sqrt_x96)

    assert sqrt_x96 > 0
    assert sqrt_price > 0
    assert price == pytest.approx(tick_to_price(tick), rel=1e-10)
    assert price_to_tick(price) == tick


def test_dbt_style_sqrt_price_helpers_are_consistent() -> None:
    tick = 196_500
    close_price_token1_in_token0 = 2050.0

    sqrt_tick = tick_to_sqrt_price(tick)
    sqrt_from_price = sqrt_price_from_human_price(
        close_price_token1_in_token0,
        token0_decimals=6,
        token1_decimals=18,
    )

    assert sqrt_tick > 0
    assert sqrt_from_price > 0


@pytest.mark.parametrize(
    ("tick_current", "expect_x_positive", "expect_y_positive"),
    [
        (195_000, True, False),
        (196_500, True, True),
        (198_000, False, True),
    ],
)
def test_compute_reserves_handles_three_regimes(
    tick_current: int,
    expect_x_positive: bool,
    expect_y_positive: bool,
) -> None:
    tick_lower = 195_600
    tick_upper = 197_400
    liquidity = 5_000_000_000_000.0

    sqrt_pa = math.sqrt(tick_to_price(tick_lower))
    sqrt_pb = math.sqrt(tick_to_price(tick_upper))
    sqrt_price = math.sqrt(tick_to_price(tick_current))

    reserve_x, reserve_y = compute_reserves(liquidity, sqrt_price, sqrt_pa, sqrt_pb)

    assert (reserve_x > 0) is expect_x_positive
    assert (reserve_y > 0) is expect_y_positive


def test_position_value_is_positive_for_in_range_position() -> None:
    tick_lower = 195_600
    tick_upper = 197_400
    tick_current = 196_500
    liquidity = 5_000_000_000_000.0

    sqrt_pa = math.sqrt(tick_to_price(tick_lower))
    sqrt_pb = math.sqrt(tick_to_price(tick_upper))
    sqrt_price = math.sqrt(tick_to_price(tick_current))
    price = tick_to_price(tick_current)

    value = compute_position_value_in_token1(liquidity, sqrt_price, sqrt_pa, sqrt_pb, price)

    assert value > 0


def test_il_is_non_positive_at_range_boundary_for_single_lot() -> None:
    tick_lower = 195_600
    tick_upper = 197_400
    tick_entry = 196_500
    tick_now = tick_lower
    liquidity = 5_000_000_000_000.0

    sqrt_pa = math.sqrt(tick_to_price(tick_lower))
    sqrt_pb = math.sqrt(tick_to_price(tick_upper))
    sqrt_entry = math.sqrt(tick_to_price(tick_entry))
    sqrt_now = math.sqrt(tick_to_price(tick_now))
    price_now = tick_to_price(tick_now)

    x0, y0 = compute_reserves(liquidity, sqrt_entry, sqrt_pa, sqrt_pb)
    position_value = compute_position_value_in_token1(
        liquidity,
        sqrt_now,
        sqrt_pa,
        sqrt_pb,
        price_now,
    )
    hodl_value = compute_hodl_value_in_token1(x0, y0, price_now)
    il = compute_il(position_value, hodl_value)

    assert il <= 1e-9


def test_liquidity_round_trip_recovers_original_amounts() -> None:
    tick_lower = 195_600
    tick_upper = 197_400
    tick_current = 196_500

    sqrt_pa = math.sqrt(tick_to_price(tick_lower))
    sqrt_pb = math.sqrt(tick_to_price(tick_upper))
    sqrt_price = math.sqrt(tick_to_price(tick_current))

    expected_liquidity = 5_000_000_000_000.0
    amount0, amount1 = compute_reserves(expected_liquidity, sqrt_price, sqrt_pa, sqrt_pb)
    liquidity = compute_liquidity_from_amounts(
        sqrt_price,
        sqrt_pa,
        sqrt_pb,
        amount0,
        amount1,
    )
    recovered_x, recovered_y = compute_reserves(liquidity, sqrt_price, sqrt_pa, sqrt_pb)

    assert recovered_x <= amount0 + 1e-9
    assert recovered_y <= amount1 + 1e-9
    assert liquidity == pytest.approx(expected_liquidity, rel=1e-9)
    assert recovered_x == pytest.approx(amount0, rel=1e-6)
    assert recovered_y == pytest.approx(amount1, rel=1e-6)


def test_range_and_lvr_helpers() -> None:
    assert is_in_range(196_500, 195_600, 197_400) is True
    assert is_in_range(197_400, 195_600, 197_400) is False

    lvr = compute_lvr_single_swap(
        sqrt_price_before=44.8,
        sqrt_price_after=44.81,
        liquidity_active=5_000_000_000_000.0,
    )
    assert lvr > 0


def test_amounts_from_liquidity_match_dbt_zero_decimal_example() -> None:
    sqrt_price_low = (1.0001 ** (10 / 2))
    sqrt_price = sqrt_price_low
    sqrt_price_high = (1.0001 ** (20 / 2))
    liquidity = 500.0

    amount0 = amount0_from_liquidity(liquidity, sqrt_price, sqrt_price_high, 0)
    amount1 = amount1_from_liquidity(liquidity, sqrt_price, sqrt_price_low, 0)

    assert amount0 == pytest.approx(0.2498000924677459, rel=1e-9)
    assert amount1 == pytest.approx(0.0, rel=1e-12)
