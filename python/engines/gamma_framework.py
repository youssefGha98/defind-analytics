"""Three-layer Gamma Framework for Uniswap v3 LPs.

Layer A — pool-level   : break_even_volatility, realized_volatility, edge,
                         full_range_equivalent_value, capital_deployed,
                         concentration_leverage, fee_to_mean_gamma_cost_ratio_pool.
Layer B — position-level: gamma_cost (total / diffusion / jump), fees, gamma_pnl,
                          fee_to_mean_gamma_cost_ratio,
                          fee_to_gamma_cost_volatility_ratio, cv_gamma_cost.
Layer C — regime / subjacent: realized_quarticity, bipower_variation,
                              jump_intensity, HAR-RV forecasts, cv_realized_il.

Nomenclature: "gamma_cost" replaces "impermanent loss". Same math, clearer econ.

The three layers are orthogonal:
  A is a property of the pool, independent of any position.
  B depends on the [Pa, Pb] choice and capital.
  C is a property of the underlying asset (price process).

Production-grade: vectorized pandas, no loops in inner formulas, OLS fit for
HAR-RV uses a rolling out-of-sample calibration window (no look-ahead).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import date

import numpy as np
import pandas as pd

from core.db import ClickHouseDB


DAYS_PER_YEAR = 365.0
HOURS_PER_DAY = 24
BV_BNS_FACTOR = math.pi / 2.0  # Barndorff-Nielsen-Shephard normalization


# ─── Position spec ────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class LpPosition:
    """Concentrated v3 LP position. L is human-scaled."""

    L: float
    Pa: float
    Pb: float
    label: str = "synthetic"

    def __post_init__(self) -> None:
        if not (self.Pa < self.Pb):
            raise ValueError(f"Pa < Pb required (got {self.Pa}, {self.Pb})")
        if self.L <= 0:
            raise ValueError(f"L > 0 required (got {self.L})")


# ─── HAR-RV forecast (rolling out-of-sample) ─────────────────────────────────
def har_rv_rolling_forecast(
    rv_daily: pd.Series,
    *,
    calib_window: int = 60,
    horizon_days: int = 1,
) -> pd.Series:
    """Rolling HAR-RV one-step-ahead forecast on daily realized variance.

    Model: RV_{t+h} = β0 + β_d · RV_t + β_w · mean_7(RV) + β_m · mean_30(RV)
    Calibrated on rolling [t − calib_window, t − 1]; forecast for t (using
    only information up to t − 1, no look-ahead).

    Returns: a series indexed like rv_daily, with NaN for warm-up days.
    """
    rv = rv_daily.astype(float).copy()
    rv_d = rv.shift(horizon_days)
    rv_w = rv.rolling(7).mean().shift(horizon_days)
    rv_m = rv.rolling(30).mean().shift(horizon_days)

    forecasts = pd.Series(np.nan, index=rv.index)
    for t in range(calib_window, len(rv)):
        train_slice = slice(t - calib_window, t)
        Y = rv.iloc[train_slice].to_numpy()
        Xd = rv_d.iloc[train_slice].to_numpy()
        Xw = rv_w.iloc[train_slice].to_numpy()
        Xm = rv_m.iloc[train_slice].to_numpy()
        ones = np.ones_like(Y)
        valid = (
            ~np.isnan(Y) & ~np.isnan(Xd) & ~np.isnan(Xw) & ~np.isnan(Xm) & (Y > 0)
        )
        if valid.sum() < 30:
            continue
        X = np.column_stack([ones[valid], Xd[valid], Xw[valid], Xm[valid]])
        try:
            beta, *_ = np.linalg.lstsq(X, Y[valid], rcond=None)
        except np.linalg.LinAlgError:
            continue
        # Forecast at t using info up to t-1
        if any(np.isnan([rv_d.iloc[t], rv_w.iloc[t], rv_m.iloc[t]])):
            continue
        x_t = np.array([1.0, rv_d.iloc[t], rv_w.iloc[t], rv_m.iloc[t]])
        forecasts.iloc[t] = float(x_t @ beta)

    return forecasts.clip(lower=0.0)  # variance is non-negative


# ─── Layer C: Subjacent vol features (per asset) ─────────────────────────────
def build_subjacent_vol_features_daily(
    db: ClickHouseDB,
    *,
    pool_for_returns: str,
    asset_label: str,
    start_date: date,
    end_date: date,
) -> pd.DataFrame:
    """Daily features of the underlying price process (Layer C).

    Output columns:
        date, asset,
        realized_volatility_annual_garman_klass,
        realized_variance_daily,
        bipower_variation_daily,
        realized_quarticity_daily,
        jump_intensity_daily,
        sigma_har_forecast_1d_annual,
        sigma_har_forecast_7d_annual,
        cv_realized_il,
    """
    intraday = db.read_query(
        f"""
        SELECT
            lower(pool) AS pool,
            date,
            hour,
            high_price,
            low_price,
            open_price,
            close_price,
            log_return_hourly
        FROM mart_price_intraday
        WHERE lower(pool) = lower('{pool_for_returns}')
          AND date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
        ORDER BY hour
        """
    ).to_pandas()
    intraday["hour"] = pd.to_datetime(intraday["hour"])
    intraday = intraday.set_index("hour").sort_index()

    r = intraday["log_return_hourly"].astype(float).fillna(0.0)
    abs_r = r.abs()
    abs_r_prev = abs_r.shift(1).fillna(0.0)

    day_key = r.index.normalize()

    rv_daily = (r * r).groupby(day_key).sum().rename("realized_variance_daily")
    rq_daily = (r ** 4).groupby(day_key).sum().rename("realized_quarticity_daily")
    bv_bns_daily = (BV_BNS_FACTOR * abs_r * abs_r_prev).groupby(day_key).sum().rename("bipower_variation_daily")

    jump_intensity = ((rv_daily - bv_bns_daily).clip(lower=0.0) / rv_daily.replace(0.0, np.nan)).fillna(0.0).rename("jump_intensity_daily")

    # Garman-Klass per hour, summed daily, annualized
    H = intraday["high_price"].astype(float)
    L = intraday["low_price"].astype(float)
    O = intraday["open_price"].astype(float)
    C = intraday["close_price"].astype(float)
    safe_L = L.where(L > 0, np.nan)
    safe_O = O.where(O > 0, np.nan)
    gk_hour = (
        0.5 * np.log(H / safe_L) ** 2
        - (2 * math.log(2) - 1) * np.log(C / safe_O) ** 2
    ).clip(lower=0.0).fillna(0.0)
    gk_daily_var = gk_hour.groupby(day_key).sum().rename("gk_daily_var")
    rv_gk_annual = (gk_daily_var * DAYS_PER_YEAR).pow(0.5).rename("realized_volatility_annual_garman_klass")

    # cv_realized_il = √RQ / RV   (vol-of-vol proxy under iid → √(3/n))
    cv_realized_il = (rq_daily.pow(0.5) / rv_daily.replace(0.0, np.nan)).rename("cv_realized_il")

    # HAR-RV forecasts on RV (variance space). Convert to vol annual at the end.
    rv_for_har = rv_daily.replace(0.0, np.nan).ffill()
    har_var_1d = har_rv_rolling_forecast(rv_for_har, calib_window=60, horizon_days=1)
    har_var_7d = har_rv_rolling_forecast(rv_for_har, calib_window=60, horizon_days=7)
    sigma_har_1d = (har_var_1d * DAYS_PER_YEAR).pow(0.5).rename("sigma_har_forecast_1d_annual")
    sigma_har_7d = (har_var_7d * DAYS_PER_YEAR).pow(0.5).rename("sigma_har_forecast_7d_annual")

    df = pd.concat(
        [rv_daily, rq_daily, bv_bns_daily, jump_intensity, rv_gk_annual,
         cv_realized_il, sigma_har_1d, sigma_har_7d],
        axis=1,
    )
    df.index.name = "date"
    df = df.reset_index()
    df.insert(0, "asset", asset_label)
    return df


# ─── Layer A: Pool gamma features ─────────────────────────────────────────────
def build_pool_gamma_features_daily(
    db: ClickHouseDB,
    *,
    pool: str,
    start_date: date,
    end_date: date,
    vol_features: pd.DataFrame | None = None,
) -> pd.DataFrame:
    """Daily Layer-A features (pool-scoped).

    Output columns:
        date, pool_address,
        volume_usd_daily, fees_usd_daily,
        liquidity_active_at_close, sqrt_price_at_close,
        full_range_equivalent_value_usd, capital_deployed_active_usd,
        concentration_leverage,
        break_even_volatility_annual_7d_window,
        break_even_volatility_annual_30d_window,
        realized_volatility_annual_7d_window,
        realized_volatility_annual_30d_window,
        volatility_edge_7d, volatility_edge_30d,
        fee_to_mean_gamma_cost_ratio_pool,
    """
    daily = db.read_query(
        f"""
        SELECT
            lower(c.pool)                       AS pool_address,
            c.date                              AS date,
            c.close_price                       AS close_price,
            toFloat64(al.active_liquidity)      AS l_active,
            atv.active_tvl_token0               AS capital_deployed_active_usd,
            v.fees_token0_equiv        AS fees_usd_daily,
            v.volume_token0_equiv      AS volume_usd_daily,
            p.token0_decimals          AS token0_decimals,
            p.token1_decimals          AS token1_decimals
        FROM int_daily_close_dense c
        INNER JOIN int_active_liquidity_daily al ON al.pool = c.pool AND al.date = c.date
        INNER JOIN int_active_tvl_daily      atv ON atv.pool = c.pool AND atv.date = c.date
        INNER JOIN mart_volume_daily         v   ON v.pool = c.pool AND v.date = c.date
        INNER JOIN stg_pools                 p   ON p.pool = c.pool
        WHERE lower(c.pool) = lower('{pool}')
          AND c.date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
        ORDER BY c.date
        """
    ).to_pandas()
    if daily.empty:
        return pd.DataFrame()

    daily["date"] = pd.to_datetime(daily["date"])
    daily = daily.sort_values("date").set_index("date")

    d0 = int(daily["token0_decimals"].iloc[0])
    d1 = int(daily["token1_decimals"].iloc[0])

    # L_human, sqrt(P_human), V_FR, concentration leverage
    daily["l_human"] = daily["l_active"] / 10 ** ((d0 + d1) / 2.0)
    daily["sqrt_price_at_close"] = np.sqrt(daily["close_price"].astype(float))
    daily["liquidity_active_at_close"] = daily["l_active"].astype(float)
    daily["full_range_equivalent_value_usd"] = 2.0 * daily["l_human"] * daily["sqrt_price_at_close"]
    daily["concentration_leverage"] = (
        daily["full_range_equivalent_value_usd"] / daily["capital_deployed_active_usd"].clip(lower=1.0)
    )

    # Realized vol windows (use vol_features if provided, else fall back to mart_price_analytics)
    if vol_features is None:
        prc = db.read_query(
            f"""
            SELECT date, realized_vol_7d AS rv7, realized_vol_30d AS rv30
            FROM mart_price_analytics_daily
            WHERE lower(pool) = lower('{pool}')
              AND date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
            """
        ).to_pandas()
        prc["date"] = pd.to_datetime(prc["date"])
        prc = prc.set_index("date")
        daily["realized_volatility_annual_7d_window"] = prc["rv7"]
        daily["realized_volatility_annual_30d_window"] = prc["rv30"]
    else:
        vf = vol_features.set_index("date")
        # Build rolling annualized vol from RV_daily (re-derive, more consistent)
        rv = vf["realized_variance_daily"]
        rv7_var = rv.rolling(7).mean()
        rv30_var = rv.rolling(30).mean()
        daily["realized_volatility_annual_7d_window"] = (rv7_var * DAYS_PER_YEAR).pow(0.5)
        daily["realized_volatility_annual_30d_window"] = (rv30_var * DAYS_PER_YEAR).pow(0.5)

    # σ*_pool from yield equilibrium: σ*² = 8 · F_annual / V_FR
    fees_7d = daily["fees_usd_daily"].rolling(7).mean() * DAYS_PER_YEAR
    fees_30d = daily["fees_usd_daily"].rolling(30).mean() * DAYS_PER_YEAR
    daily["break_even_volatility_annual_7d_window"] = np.sqrt(
        np.clip(8.0 * fees_7d / daily["full_range_equivalent_value_usd"].clip(lower=1.0), 0.0, None)
    )
    daily["break_even_volatility_annual_30d_window"] = np.sqrt(
        np.clip(8.0 * fees_30d / daily["full_range_equivalent_value_usd"].clip(lower=1.0), 0.0, None)
    )

    daily["volatility_edge_7d"] = (
        daily["break_even_volatility_annual_7d_window"]
        - daily["realized_volatility_annual_7d_window"]
    )
    daily["volatility_edge_30d"] = (
        daily["break_even_volatility_annual_30d_window"]
        - daily["realized_volatility_annual_30d_window"]
    )

    # Pool-level FGY: ratio of fees to expected gamma cost on the V_FR equivalent
    # E[gamma_cost_FR_daily] = V_FR/8 × σ²_realized × Δt(=1/365 yr) = V_FR × RV_daily / 8
    # if vol_features available; otherwise approximate from realized_vol_7d_annual.
    if vol_features is not None:
        vf = vol_features.set_index("date")
        e_gc_fr_daily = daily["full_range_equivalent_value_usd"] / 8.0 * vf["realized_variance_daily"]
    else:
        # σ²_daily = σ²_annual / 365
        e_gc_fr_daily = (
            daily["full_range_equivalent_value_usd"] / 8.0
            * (daily["realized_volatility_annual_7d_window"] ** 2) / DAYS_PER_YEAR
        )
    daily["fee_to_mean_gamma_cost_ratio_pool"] = (
        daily["fees_usd_daily"] / e_gc_fr_daily.where(e_gc_fr_daily > 0, np.nan)
    )

    out = daily.reset_index()[
        [
            "date", "pool_address", "volume_usd_daily", "fees_usd_daily",
            "liquidity_active_at_close", "sqrt_price_at_close",
            "full_range_equivalent_value_usd", "capital_deployed_active_usd",
            "concentration_leverage",
            "break_even_volatility_annual_7d_window",
            "break_even_volatility_annual_30d_window",
            "realized_volatility_annual_7d_window",
            "realized_volatility_annual_30d_window",
            "volatility_edge_7d", "volatility_edge_30d",
            "fee_to_mean_gamma_cost_ratio_pool",
        ]
    ]
    # Ensure native float types (no Int128)
    return out.astype(
        {
            "volume_usd_daily": "float64",
            "fees_usd_daily": "float64",
            "liquidity_active_at_close": "float64",
            "capital_deployed_active_usd": "float64",
        }
    )


# ─── Layer B: Position gamma features ─────────────────────────────────────────
def _gamma_at(L: float, P: np.ndarray, Pa: float, Pb: float) -> np.ndarray:
    """Γ_t = -L / (2·P^(3/2)) when in [Pa, Pb], else 0."""
    in_range = (P >= Pa) & (P <= Pb)
    gamma = np.where(in_range, -L / (2.0 * np.power(P, 1.5)), 0.0)
    return gamma, in_range


def build_position_gamma_features_daily(
    db: ClickHouseDB,
    *,
    pool: str,
    position: LpPosition,
    start_date: date,
    end_date: date,
    vol_features: pd.DataFrame,
    pool_features: pd.DataFrame,
    position_share: float = 1.0,
) -> pd.DataFrame:
    """Daily Layer-B features (position-scoped).

    `position_share` ∈ [0, 1] applies a multiplicative factor on pool fees to
    represent the fraction of pool fees this position would capture when in-range
    (`share = L_position / pool_active_L_active_when_in_range`).

    Output columns:
        date, pool_address, position_id,
        range_lower_price, range_upper_price, range_width_pct,
        liquidity_position, capital_deployed_position_usd,
        time_in_range_fraction,
        fees_position_usd_daily,
        gamma_cost_expected_usd_daily, gamma_cost_realized_usd_daily,
        gamma_cost_volatility_usd_daily,
        diffusion_gamma_cost_usd_daily, jump_gamma_cost_usd_daily,
        gamma_pnl_usd_daily,
        fee_to_mean_gamma_cost_ratio,
        fee_to_gamma_cost_volatility_ratio,
        cv_gamma_cost,
    """
    intraday = db.read_query(
        f"""
        SELECT
            hour, close_price, log_return_hourly
        FROM mart_price_intraday
        WHERE lower(pool) = lower('{pool}')
          AND date BETWEEN toDate('{start_date}') AND toDate('{end_date}')
        ORDER BY hour
        """
    ).to_pandas()
    intraday["hour"] = pd.to_datetime(intraday["hour"])
    intraday = intraday.set_index("hour").sort_index()
    P = intraday["close_price"].astype(float).to_numpy()
    r = intraday["log_return_hourly"].astype(float).fillna(0.0).to_numpy()

    gamma, in_range = _gamma_at(position.L, P, position.Pa, position.Pb)
    abs_gamma = np.abs(gamma)
    il_increment = 0.5 * abs_gamma * np.power(P, 2.0) * np.power(r, 2.0)
    capital_position_t = np.where(in_range, 2.0 * position.L * np.sqrt(P), 0.0)

    hf = pd.DataFrame(
        {
            "price": P,
            "in_range": in_range.astype(float),
            "abs_gamma": abs_gamma,
            "il_increment": il_increment,
            "capital_position": capital_position_t,
        },
        index=intraday.index,
    )

    day_key = hf.index.normalize()
    daily_il_realized = hf["il_increment"].groupby(day_key).sum()
    daily_in_range = hf["in_range"].groupby(day_key).mean()  # fraction of hours
    daily_capital = hf["capital_position"].groupby(day_key).mean()

    daily = pd.DataFrame(
        {
            "gamma_cost_realized_usd_daily": daily_il_realized,
            "time_in_range_fraction": daily_in_range,
            "capital_deployed_position_usd": daily_capital,
        }
    )
    daily.index.name = "date"

    # Layer C inputs (RV, BV, RQ) for decomposition + expected
    vf = vol_features.set_index("date")
    rv = vf["realized_variance_daily"]
    bv = vf["bipower_variation_daily"]
    rq = vf["realized_quarticity_daily"]
    jump = (rv - bv).clip(lower=0.0)
    bv_share = (bv / rv.where(rv > 0, np.nan)).clip(0.0, 1.0).fillna(0.0)
    jump_share = (jump / rv.where(rv > 0, np.nan)).clip(0.0, 1.0).fillna(0.0)

    daily["bv_share"] = bv_share.reindex(daily.index)
    daily["jump_share"] = jump_share.reindex(daily.index)
    daily["diffusion_gamma_cost_usd_daily"] = (daily["gamma_cost_realized_usd_daily"] * daily["bv_share"]).fillna(0.0)
    daily["jump_gamma_cost_usd_daily"] = (daily["gamma_cost_realized_usd_daily"] * daily["jump_share"]).fillna(0.0)

    # E[gamma_cost] under diffusion: L·√P · σ²·Δt / 4
    # Use position-level: only when in-range. Approximate σ²·Δt ≈ RV_daily.
    pf = pool_features.set_index("date")
    sqrt_p = pf["sqrt_price_at_close"].reindex(daily.index)
    daily["gamma_cost_expected_usd_daily"] = (
        position.L * sqrt_p * rv.reindex(daily.index) / 4.0 * daily["time_in_range_fraction"]
    )
    # Std of gamma_cost via realized quarticity heuristic
    daily["gamma_cost_volatility_usd_daily"] = (
        position.L * sqrt_p * rq.reindex(daily.index).pow(0.5) / 4.0 * daily["time_in_range_fraction"]
    )

    # cv_gamma_cost = √RQ / RV (subjacent-only, range-invariant)
    cv = (rq.pow(0.5) / rv.where(rv > 0, np.nan)).rename("cv_gamma_cost")
    daily["cv_gamma_cost"] = cv.reindex(daily.index)

    # Position fees: pool fees × in-range fraction × position share
    pool_fees = pf["fees_usd_daily"].reindex(daily.index)
    daily["fees_position_usd_daily"] = (
        pool_fees.fillna(0.0) * daily["time_in_range_fraction"].fillna(0.0) * float(position_share)
    )

    daily["gamma_pnl_usd_daily"] = (
        daily["fees_position_usd_daily"] - daily["gamma_cost_realized_usd_daily"]
    )

    # Window-level ratios (FGY and GSR computed as scalars, broadcast)
    mean_fees = float(daily["fees_position_usd_daily"].mean())
    mean_gc = float(daily["gamma_cost_realized_usd_daily"].mean())
    std_gc = float(daily["gamma_cost_realized_usd_daily"].std(ddof=1))

    fgy_total = mean_fees / mean_gc if mean_gc > 0 else np.nan
    gsr = (mean_fees - mean_gc) / std_gc if std_gc > 0 else np.nan
    daily["fee_to_mean_gamma_cost_ratio"] = fgy_total
    daily["fee_to_gamma_cost_volatility_ratio"] = gsr

    # Identifying columns
    daily["pool_address"] = pool.lower()
    daily["position_id"] = position.label
    daily["range_lower_price"] = position.Pa
    daily["range_upper_price"] = position.Pb
    daily["range_width_pct"] = math.log(position.Pb / position.Pa)
    daily["liquidity_position"] = position.L

    out = daily.reset_index()[
        [
            "date", "pool_address", "position_id",
            "range_lower_price", "range_upper_price", "range_width_pct",
            "liquidity_position", "capital_deployed_position_usd",
            "time_in_range_fraction",
            "fees_position_usd_daily",
            "gamma_cost_expected_usd_daily", "gamma_cost_realized_usd_daily",
            "gamma_cost_volatility_usd_daily",
            "diffusion_gamma_cost_usd_daily", "jump_gamma_cost_usd_daily",
            "gamma_pnl_usd_daily",
            "fee_to_mean_gamma_cost_ratio",
            "fee_to_gamma_cost_volatility_ratio",
            "cv_gamma_cost",
        ]
    ]
    return out.astype({"liquidity_position": "float64"})


# ─── Pipeline orchestrator ────────────────────────────────────────────────────
@dataclass(frozen=True)
class GammaFrameworkOutput:
    vol_features: pd.DataFrame
    pool_features: pd.DataFrame
    position_features: pd.DataFrame


def run_gamma_framework(
    db: ClickHouseDB,
    *,
    pool: str,
    position: LpPosition,
    start_date: date,
    end_date: date,
    asset_label: str = "ETH",
    position_share: float = 1.0,
    write: bool = False,
    pool_table: str = "py_pool_gamma_features_daily",
    position_table: str = "py_position_gamma_features_daily",
    vol_table: str = "py_subjacent_vol_features_daily",
) -> GammaFrameworkOutput:
    """Build all three marts. If write=True, persist them to ClickHouse."""
    vol_features = build_subjacent_vol_features_daily(
        db, pool_for_returns=pool, asset_label=asset_label,
        start_date=start_date, end_date=end_date,
    )
    pool_features = build_pool_gamma_features_daily(
        db, pool=pool, start_date=start_date, end_date=end_date,
        vol_features=vol_features,
    )
    position_features = build_position_gamma_features_daily(
        db, pool=pool, position=position, start_date=start_date, end_date=end_date,
        vol_features=vol_features, pool_features=pool_features,
        position_share=position_share,
    )

    if write:
        import polars as pl

        def _to_polars_safe(pdf: pd.DataFrame) -> pl.DataFrame:
            """Cast all non-id numeric columns to Float64 to avoid Int128 leaks."""
            id_cols = {"date", "pool_address", "position_id", "asset"}
            df = pdf.copy()
            for c in df.columns:
                if c in id_cols:
                    continue
                try:
                    df[c] = df[c].astype("float64")
                except (TypeError, ValueError):
                    pass
            return pl.from_pandas(df)

        if not vol_features.empty:
            db.write_table(_to_polars_safe(vol_features), vol_table,
                           create_if_missing=True, order_by=["asset", "date"])
        if not pool_features.empty:
            db.write_table(_to_polars_safe(pool_features), pool_table,
                           create_if_missing=True, order_by=["pool_address", "date"])
        if not position_features.empty:
            db.write_table(_to_polars_safe(position_features), position_table,
                           create_if_missing=True, order_by=["pool_address", "position_id", "date"])

    return GammaFrameworkOutput(
        vol_features=vol_features,
        pool_features=pool_features,
        position_features=position_features,
    )
