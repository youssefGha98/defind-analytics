"""Gamma Sharpe Ratio engine — POC v0.

Builds a daily series of:
  σ*_pool   — pool-implied vol from yield equilibrium  (σ*² = 8·F / TVL_FR)
  σ_realized — Garman-Klass on hourly OHLC, annualized
  CV[IL]    — std / mean of the daily IL cost (heuristic via realized quarticity)
  edge      — σ*_pool − σ_realized

Output mart: `py_pool_gsr_daily`, one row per (pool, date).
"""

from __future__ import annotations

import math
from datetime import date
from typing import Optional

import polars as pl

from core.db import ClickHouseDB


# Hourly observations per day used for the realized-vol estimators.
HOURS_PER_DAY = 24
DAYS_PER_YEAR = 365.0
GK_C1 = 0.5
GK_C2 = 2.0 * math.log(2.0) - 1.0  # ≈ 0.386


def _read_inputs(
    db: ClickHouseDB,
    *,
    pool: str,
    start_date: date,
    end_date: date,
) -> tuple[pl.DataFrame, pl.DataFrame]:
    """Read the daily and intraday inputs needed to build the GSR mart.

    Returns (daily, intraday_aggregated).
    """
    daily = db.read_query(
        f"""
        SELECT
            lower(c.pool)              AS pool,
            c.date                     AS date,
            c.close_price              AS close_price,
            al.active_liquidity        AS l_active,
            atv.active_tvl_token0      AS active_tvl_usd,
            v.fees_token0_equiv        AS fees_daily,
            v.volume_token0_equiv      AS volume_daily,
            p.token0_decimals          AS token0_decimals,
            p.token1_decimals          AS token1_decimals
        FROM int_daily_close_dense c
        INNER JOIN int_active_liquidity_daily al
            ON al.pool = c.pool AND al.date = c.date
        INNER JOIN int_active_tvl_daily atv
            ON atv.pool = c.pool AND atv.date = c.date
        INNER JOIN mart_volume_daily v
            ON v.pool = c.pool AND v.date = c.date
        INNER JOIN stg_pools p
            ON p.pool = c.pool
        WHERE lower(c.pool) = lower('{pool}')
          AND c.date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
        ORDER BY c.date
        """
    )

    intraday = db.read_query(
        f"""
        SELECT
            lower(pool) AS pool,
            date,
            -- Garman-Klass per hour (pre-summed in build_pool_gsr_daily)
            sum(
                0.5 * pow(log(high_price / nullIf(low_price, 0)), 2)
                - (2 * log(2) - 1)
                  * pow(log(close_price / nullIf(open_price, 0)), 2)
            ) AS gk_daily_var,
            -- Realized variance proxy (Σ r_h²)
            sum(pow(coalesce(log_return_hourly, 0), 2)) AS sum_r2,
            -- Realized quarticity (Σ r_h⁴)
            sum(pow(coalesce(log_return_hourly, 0), 4)) AS sum_r4,
            count() AS n_hours,
            countIf(log_return_hourly IS NOT NULL) AS n_returns
        FROM mart_price_intraday
        WHERE lower(pool) = lower('{pool}')
          AND date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
        GROUP BY pool, date
        """
    )
    return daily, intraday


def build_pool_gsr_daily(
    db: ClickHouseDB,
    *,
    pool: str,
    start_date: date,
    end_date: date,
) -> pl.DataFrame:
    """Compute the Gamma-Sharpe daily mart for a pool over [start_date, end_date].

    Output columns (one row per (pool, date)):
        date, pool_address,
        V_usd, L_active, sqrt_P, TVL_FR_usd,
        fees_daily, fees_7d_usd,
        sigma_star_pool_daily_annual, sigma_star_pool_7d_annual,
        sigma_realized_annual,
        edge,                    # = σ*_pool_7d − σ_realized
        E_abs_IL, std_IL, cv_IL,
        n_hours, n_returns       # data-quality flags
    """
    daily, intraday = _read_inputs(db, pool=pool, start_date=start_date, end_date=end_date)
    if daily.is_empty():
        return pl.DataFrame()

    # Join daily ⊕ intraday aggregates.
    df = daily.join(intraday, on=["pool", "date"], how="left")

    # ─── L_human and TVL_FR ────────────────────────────────────────────────
    # L_human = L_raw / 10^((d0+d1)/2)
    # TVL_FR_usd = 2 · L_h · √P_h   (P_h = price_token1_in_token0_human, USDC/WETH for our pool)
    df = df.with_columns(
        (
            pl.col("l_active")
            / pl.lit(10.0).pow((pl.col("token0_decimals") + pl.col("token1_decimals")).cast(pl.Float64) / 2.0)
        ).alias("l_human"),
        pl.col("close_price").sqrt().alias("sqrt_p"),
    ).with_columns(
        (2.0 * pl.col("l_human") * pl.col("sqrt_p")).alias("tvl_fr_usd"),
    )

    # ─── F windows ─────────────────────────────────────────────────────────
    df = df.sort("date").with_columns(
        pl.col("fees_daily")
        .rolling_sum(window_size=7, min_samples=1)
        .alias("fees_7d_usd"),
    )

    # ─── σ*_pool annualized ────────────────────────────────────────────────
    # σ*² = 8 · F_annual / TVL_FR
    #   F_annual_from_daily = F_daily × 365
    #   F_annual_from_7d    = F_7d / 7 × 365
    df = df.with_columns(
        (
            8.0 * pl.col("fees_daily") * DAYS_PER_YEAR
            / pl.col("tvl_fr_usd").clip(1e-9, None)
        ).alias("sigma_star_pool_daily_var_annual"),
        (
            8.0 * pl.col("fees_7d_usd") / 7.0 * DAYS_PER_YEAR
            / pl.col("tvl_fr_usd").clip(1e-9, None)
        ).alias("sigma_star_pool_7d_var_annual"),
    ).with_columns(
        pl.col("sigma_star_pool_daily_var_annual")
        .clip(0.0, None)
        .sqrt()
        .alias("sigma_star_pool_daily_annual"),
        pl.col("sigma_star_pool_7d_var_annual")
        .clip(0.0, None)
        .sqrt()
        .alias("sigma_star_pool_7d_annual"),
    )

    # ─── σ_realized annualized via Garman-Klass on hourly OHLC ─────────────
    # gk_daily_var = Σ_hour [0.5·ln(H/L)² − (2·ln2 − 1)·ln(C/O)²]
    # σ²_annual = gk_daily_var × 365
    df = df.with_columns(
        (pl.col("gk_daily_var").clip(0.0, None) * DAYS_PER_YEAR)
        .alias("sigma_realized_var_annual"),
    ).with_columns(
        pl.col("sigma_realized_var_annual").sqrt().alias("sigma_realized_annual"),
    )

    # ─── edge ──────────────────────────────────────────────────────────────
    # Use the lower-noise σ*_pool_7d as the primary edge signal.
    df = df.with_columns(
        (pl.col("sigma_star_pool_7d_annual") - pl.col("sigma_realized_annual")).alias("edge"),
    )

    # ─── E[|IL|] and Std[IL] (heuristic via quarticity) ────────────────────
    # E[|IL|]_window = L_h · √P · σ²·Δt / 4    (standard CFMM IL approximation)
    #               ≈ L_h · √P · Σr² / 4       (since σ²·Δt = realized variance over the window)
    # Std[IL]_window heuristic via integrated quarticity:
    #   Std[Σr²] ≈ √(Σr⁴)   ⇒   Std[IL] ≈ L_h · √P · √(Σr⁴) / 4
    # CV[IL] = Std/E ≈ √(Σr⁴) / Σr²    (dimensionless, ≈ √(kurtosis/N) under iid)
    df = df.with_columns(
        (pl.col("l_human") * pl.col("sqrt_p") * pl.col("sum_r2") / 4.0).alias("e_abs_il"),
        (pl.col("l_human") * pl.col("sqrt_p") * pl.col("sum_r4").sqrt() / 4.0).alias("std_il"),
    ).with_columns(
        (pl.col("std_il") / pl.col("e_abs_il").clip(1e-12, None)).alias("cv_il"),
    )

    # ─── Final output columns ──────────────────────────────────────────────
    # Cast L_active to Float64 (raw V3 liquidity is up to ~10^19, comfortably
    # within Float64 precision; core.db.write_table doesn't support Int128).
    return df.select(
        pl.col("date"),
        pl.col("pool").alias("pool_address"),
        pl.col("active_tvl_usd").alias("V_usd"),
        pl.col("l_active").cast(pl.Float64).alias("L_active"),
        pl.col("sqrt_p").alias("sqrt_P"),
        pl.col("tvl_fr_usd").alias("TVL_FR_usd"),
        pl.col("fees_daily").alias("fees_daily_usd"),
        pl.col("fees_7d_usd").alias("fees_7d_usd"),
        pl.col("sigma_star_pool_daily_annual"),
        pl.col("sigma_star_pool_7d_annual"),
        pl.col("sigma_realized_annual"),
        pl.col("edge"),
        pl.col("e_abs_il").alias("E_abs_IL"),
        pl.col("std_il").alias("std_IL"),
        pl.col("cv_il").alias("cv_IL"),
        pl.col("n_hours"),
        pl.col("n_returns"),
    )


def summarize_gsr(gsr: pl.DataFrame) -> dict:
    """Aggregate sanity stats over the loaded window."""
    if gsr.is_empty():
        return {"rows": 0}
    return {
        "rows": gsr.height,
        "min_date": gsr["date"].min(),
        "max_date": gsr["date"].max(),
        "avg_TVL_FR_usd": float(gsr["TVL_FR_usd"].mean()),
        "avg_active_TVL_usd": float(gsr["V_usd"].mean()),
        "concentration_leverage": float((gsr["TVL_FR_usd"] / gsr["V_usd"].clip(1.0, None)).mean()),
        "avg_volume_daily_usd": float(gsr["fees_daily_usd"].mean() / 0.0005),  # rough back-out from fees
        "avg_sigma_star_7d": float(gsr["sigma_star_pool_7d_annual"].mean()),
        "avg_sigma_realized": float(gsr["sigma_realized_annual"].mean()),
        "avg_edge": float(gsr["edge"].mean()),
        "avg_cv_il": float(gsr["cv_IL"].mean()),
        "fees_total_usd": float(gsr["fees_daily_usd"].sum()),
    }


def run_pool_gsr(
    db: ClickHouseDB,
    *,
    pool: str,
    start_date: date,
    end_date: date,
    write: bool = False,
    output_table: str = "py_pool_gsr_daily",
) -> pl.DataFrame:
    gsr = build_pool_gsr_daily(db, pool=pool, start_date=start_date, end_date=end_date)
    if write and not gsr.is_empty():
        db.write_table(
            gsr,
            output_table,
            create_if_missing=True,
            order_by=["pool_address", "date"],
        )
    return gsr
