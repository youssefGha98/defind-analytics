"""Stateless Uniswap V3 math helpers for analytics workloads."""

from __future__ import annotations

import math


Q96 = 2 ** 96
MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
_LOG_1_0001 = math.log(1.0001)


def _validate_tick(tick: int) -> None:
    if tick < MIN_TICK or tick > MAX_TICK:
        raise ValueError(f"tick out of bounds: {tick}")


def _validate_price(price: float) -> None:
    if not math.isfinite(price) or price <= 0:
        raise ValueError(f"price must be positive and finite, got {price}")


def _validate_sqrt_price(sqrt_price: float, *, name: str) -> None:
    if not math.isfinite(sqrt_price) or sqrt_price <= 0:
        raise ValueError(f"{name} must be positive and finite, got {sqrt_price}")


def _validate_range_bounds(sqrt_pa: float, sqrt_pb: float) -> None:
    _validate_sqrt_price(sqrt_pa, name="sqrt_pa")
    _validate_sqrt_price(sqrt_pb, name="sqrt_pb")
    if sqrt_pa >= sqrt_pb:
        raise ValueError("sqrt_pa must be strictly less than sqrt_pb")


def tick_to_sqrt_price_x96(tick: int) -> int:
    """Return sqrt(1.0001^tick) scaled by Q96."""

    _validate_tick(tick)
    sqrt_price = math.exp(0.5 * tick * _LOG_1_0001)
    sqrt_price_x96 = int(sqrt_price * Q96)
    return max(MIN_SQRT_RATIO, min(MAX_SQRT_RATIO, sqrt_price_x96))


def tick_to_price(tick: int) -> float:
    """Return token0/token1 price implied by the tick."""

    _validate_tick(tick)
    return math.exp(tick * _LOG_1_0001)


def tick_to_sqrt_price(tick: int) -> float:
    """Return the normalized V3 sqrt price used by the dbt math macros."""

    _validate_tick(tick)
    return math.exp(0.5 * tick * _LOG_1_0001)


def sqrt_price_x96_to_float(sqrt_price_x96: int) -> float:
    """Convert a Q96 sqrt price integer to a float sqrt price."""

    if sqrt_price_x96 <= 0:
        raise ValueError("sqrt_price_x96 must be positive")
    return sqrt_price_x96 / Q96


def sqrt_price_x96_to_price(sqrt_price_x96: int) -> float:
    """Convert a Q96 sqrt price integer to a float spot price."""

    sqrt_price = sqrt_price_x96_to_float(sqrt_price_x96)
    return sqrt_price * sqrt_price


def price_to_tick(price: float) -> int:
    """Return the floor tick implied by a positive spot price."""

    _validate_price(price)
    tick = math.floor(math.log(price) / _LOG_1_0001)
    return max(MIN_TICK, min(MAX_TICK, tick))


def sqrt_price_from_human_price(
    price_token1_in_token0: float,
    token0_decimals: int,
    token1_decimals: int,
) -> float:
    """Match dbt sqrt_price_from_price for human price_token1_in_token0 inputs."""

    _validate_price(price_token1_in_token0)
    decimal_factor = 10.0 ** (token1_decimals - token0_decimals)
    return math.sqrt(decimal_factor / price_token1_in_token0)


def compute_reserves(
    L: float,
    sqrt_price: float,
    sqrt_pa: float,
    sqrt_pb: float,
) -> tuple[float, float]:
    """Compute token0/token1 virtual reserves for a position."""

    if not math.isfinite(L) or L < 0:
        raise ValueError(f"L must be non-negative and finite, got {L}")
    _validate_sqrt_price(sqrt_price, name="sqrt_price")
    _validate_range_bounds(sqrt_pa, sqrt_pb)

    if L == 0:
        return 0.0, 0.0

    if sqrt_price <= sqrt_pa:
        x = L * ((1.0 / sqrt_pa) - (1.0 / sqrt_pb))
        return x, 0.0

    if sqrt_price >= sqrt_pb:
        y = L * (sqrt_pb - sqrt_pa)
        return 0.0, y

    x = L * ((1.0 / sqrt_price) - (1.0 / sqrt_pb))
    y = L * (sqrt_price - sqrt_pa)
    return x, y


def amount0_from_liquidity(
    liquidity: float,
    sqrt_price: float,
    sqrt_price_high: float,
    token0_decimals: int,
) -> float:
    """Match dbt amount0_from_liquidity on human token0 units."""

    if not math.isfinite(liquidity) or liquidity < 0:
        raise ValueError(f"liquidity must be non-negative and finite, got {liquidity}")
    _validate_sqrt_price(sqrt_price, name="sqrt_price")
    _validate_sqrt_price(sqrt_price_high, name="sqrt_price_high")
    if sqrt_price > sqrt_price_high:
        raise ValueError("sqrt_price must be <= sqrt_price_high")
    return (
        liquidity
        * (sqrt_price_high - sqrt_price)
        / (sqrt_price * sqrt_price_high)
        / (10.0 ** token0_decimals)
    )


def amount1_from_liquidity(
    liquidity: float,
    sqrt_price: float,
    sqrt_price_low: float,
    token1_decimals: int,
) -> float:
    """Match dbt amount1_from_liquidity on human token1 units."""

    if not math.isfinite(liquidity) or liquidity < 0:
        raise ValueError(f"liquidity must be non-negative and finite, got {liquidity}")
    _validate_sqrt_price(sqrt_price, name="sqrt_price")
    _validate_sqrt_price(sqrt_price_low, name="sqrt_price_low")
    if sqrt_price < sqrt_price_low:
        raise ValueError("sqrt_price must be >= sqrt_price_low")
    return (
        liquidity
        * (sqrt_price - sqrt_price_low)
        / (10.0 ** token1_decimals)
    )


def compute_position_value_in_token1(
    L: float,
    sqrt_price: float,
    sqrt_pa: float,
    sqrt_pb: float,
    price: float,
) -> float:
    _validate_price(price)
    x, y = compute_reserves(L, sqrt_price, sqrt_pa, sqrt_pb)
    return (x * price) + y


def compute_position_value_in_token0(
    L: float,
    sqrt_price: float,
    sqrt_pa: float,
    sqrt_pb: float,
    price: float,
) -> float:
    _validate_price(price)
    x, y = compute_reserves(L, sqrt_price, sqrt_pa, sqrt_pb)
    return x + (y / price)


def compute_hodl_value_in_token1(x0: float, y0: float, price_now: float) -> float:
    _validate_price(price_now)
    return (x0 * price_now) + y0


def compute_il(position_value: float, hodl_value: float) -> float:
    if not math.isfinite(position_value) or not math.isfinite(hodl_value):
        raise ValueError("position_value and hodl_value must be finite")
    return position_value - hodl_value


def compute_liquidity_from_amounts(
    sqrt_price: float,
    sqrt_pa: float,
    sqrt_pb: float,
    amount0: float,
    amount1: float,
) -> float:
    """Infer the effective liquidity from token amounts."""

    _validate_sqrt_price(sqrt_price, name="sqrt_price")
    _validate_range_bounds(sqrt_pa, sqrt_pb)
    if not math.isfinite(amount0) or amount0 < 0:
        raise ValueError(f"amount0 must be non-negative and finite, got {amount0}")
    if not math.isfinite(amount1) or amount1 < 0:
        raise ValueError(f"amount1 must be non-negative and finite, got {amount1}")

    if sqrt_price <= sqrt_pa:
        denominator = (1.0 / sqrt_pa) - (1.0 / sqrt_pb)
        return 0.0 if denominator == 0 else amount0 / denominator

    if sqrt_price >= sqrt_pb:
        denominator = sqrt_pb - sqrt_pa
        return 0.0 if denominator == 0 else amount1 / denominator

    liquidity0 = math.inf if amount0 == 0 else amount0 / ((1.0 / sqrt_price) - (1.0 / sqrt_pb))
    liquidity1 = math.inf if amount1 == 0 else amount1 / (sqrt_price - sqrt_pa)
    liquidity = min(liquidity0, liquidity1)
    if math.isinf(liquidity):
        return 0.0
    return liquidity


def is_in_range(tick_current: int, tick_lower: int, tick_upper: int) -> bool:
    _validate_tick(tick_current)
    _validate_tick(tick_lower)
    _validate_tick(tick_upper)
    if tick_lower >= tick_upper:
        raise ValueError("tick_lower must be strictly less than tick_upper")
    return tick_lower <= tick_current < tick_upper


def compute_lvr_single_swap(
    sqrt_price_before: float,
    sqrt_price_after: float,
    liquidity_active: float,
) -> float:
    _validate_sqrt_price(sqrt_price_before, name="sqrt_price_before")
    _validate_sqrt_price(sqrt_price_after, name="sqrt_price_after")
    if not math.isfinite(liquidity_active) or liquidity_active < 0:
        raise ValueError(
            f"liquidity_active must be non-negative and finite, got {liquidity_active}"
        )
    delta = sqrt_price_after - sqrt_price_before
    return liquidity_active * delta * delta / 2.0
