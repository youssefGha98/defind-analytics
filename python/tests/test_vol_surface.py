from __future__ import annotations

import math

import polars as pl

from analytics.vol_surface import (
    assign_moneyness_bucket,
    build_daily_sigma_by_tick,
    build_moneyness_surface,
    smooth_surface,
    tick_to_log_moneyness,
)


def test_tick_to_log_moneyness_atm_is_near_zero() -> None:
    tick = 196_500
    spot = math.exp(tick * math.log(1.0001))
    assert abs(tick_to_log_moneyness(tick, spot)) < 1e-12


def test_tick_to_log_moneyness_otm_is_positive() -> None:
    tick = 197_400
    spot = math.exp(196_500 * math.log(1.0001))
    assert tick_to_log_moneyness(tick, spot) > 0


def test_assign_moneyness_bucket_rounds_to_center() -> None:
    assert assign_moneyness_bucket(0.024, 0.05) == 0.0
    assert assign_moneyness_bucket(0.026, 0.05) == 0.05
    assert assign_moneyness_bucket(-0.074, 0.05) == -0.05
    assert assign_moneyness_bucket(-0.076, 0.05) == -0.1


def test_build_daily_sigma_by_tick_liquidity_weights() -> None:
    hourly = pl.DataFrame({
        "pool": ["p", "p", "p"],
        "date": [
            pl.Series([None]).cast(pl.Date).item(),
        ] * 3,
        "tick": [100, 100, 100],
        "sigma_evc": [0.4, 0.6, 0.8],
        "tick_liquidity": [100.0, 200.0, 100.0],
    }).with_columns(pl.lit("2024-01-01").str.to_date().alias("date"))

    result = build_daily_sigma_by_tick(hourly)

    assert result.height == 1
    expected = (0.4 * 100 + 0.6 * 200 + 0.8 * 100) / 400
    assert result["sigma_evc"][0] == expected
    assert result["tick_liquidity"][0] == 400.0


def test_build_moneyness_surface_groups_ticks_into_buckets() -> None:
    daily_sigma = pl.DataFrame({
        "pool": ["p", "p"],
        "date": [
            pl.Series(["2024-01-01", "2024-01-01"]).str.to_date().to_list()[0],
            pl.Series(["2024-01-01", "2024-01-01"]).str.to_date().to_list()[1],
        ],
        "tick": [196_500, 196_510],
        "sigma_evc": [0.5, 0.6],
        "tick_liquidity": [1000.0, 2000.0],
    })
    daily_close = pl.DataFrame({
        "pool": ["p"],
        "date": [pl.Series(["2024-01-01"]).str.to_date().to_list()[0]],
        "close_price": [math.exp(196_500 * math.log(1.0001))],
    })

    result = build_moneyness_surface(daily_sigma, daily_close, bucket_width=0.05)

    assert result.height >= 1
    assert "sigma_evc_raw" in result.columns
    assert result["tick_count"].sum() == 2
    assert result["total_liquidity"].sum() == 3000.0


def test_smooth_surface_applies_cross_section_and_temporal() -> None:
    surface = pl.DataFrame({
        "pool": ["p"] * 6,
        "day": pl.Series(["2024-01-01"] * 3 + ["2024-01-02"] * 3).str.to_date(),
        "moneyness_bucket": [-0.05, 0.0, 0.05, -0.05, 0.0, 0.05],
        "sigma_evc_raw": [0.3, 0.5, 0.7, 0.35, 0.55, 0.75],
        "tick_count": [10, 20, 10, 10, 20, 10],
        "total_liquidity": [100.0, 200.0, 100.0, 100.0, 200.0, 100.0],
    })

    result = smooth_surface(surface, cross_section_window=3, temporal_halflife_days=3)

    assert "sigma_evc_smoothed" in result.columns
    assert result.height == 6
    smoothed = result.filter(
        (pl.col("day") == pl.Series(["2024-01-02"]).str.to_date()[0])
        & (pl.col("moneyness_bucket") == 0.0)
    )["sigma_evc_smoothed"]
    assert len(smoothed) == 1
    assert smoothed[0] > 0


def test_build_daily_sigma_empty_input() -> None:
    hourly = pl.DataFrame(schema={
        "pool": pl.String,
        "date": pl.Date,
        "tick": pl.Int32,
        "sigma_evc": pl.Float64,
        "tick_liquidity": pl.Float64,
    })
    result = build_daily_sigma_by_tick(hourly)
    assert result.is_empty()


def test_smooth_surface_empty_input() -> None:
    surface = pl.DataFrame(schema={
        "pool": pl.String,
        "day": pl.Date,
        "moneyness_bucket": pl.Float64,
        "sigma_evc_raw": pl.Float64,
        "tick_count": pl.UInt32,
        "total_liquidity": pl.Float64,
    })
    result = smooth_surface(surface)
    assert result.is_empty()
    assert "sigma_evc_smoothed" in result.columns
