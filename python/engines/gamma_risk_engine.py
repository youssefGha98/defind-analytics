"""Gamma-risk framework for Uniswap v3 LP positions.

Production-grade vectorized pandas implementation. All units are token0_equiv (USD
for USDC-quoted pools). Returns are log returns. Aggregation grain is daily.

Pipeline:
    1. compute_gamma           Γ_t = -L / (2·P^(3/2))   if P ∈ [Pa, Pb] else 0
    2. compute_realized_il     IL_increment_t = 0.5 · |Γ_t| · P_t² · r_t²
    3. compute_rv_bv_jumps     RV_d = Σr², BV_d = Σ|r·r'|, Jump_d = max(RV − BV, 0)
    4. decompose_il            IL_diffusion = IL × (BV/RV), IL_jump = IL × (Jump/RV)
    5. compute_metrics         FGY, GSR, σ*, GammaPnL series
    6. compute_tail_diagnostics  % positive days, worst-5 contribution, skew(IL)

All functions are pure (no side effects) and use vectorized pandas. Time index
must be tz-naive datetime; returns must be aligned with prices on the same index.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import pandas as pd


# Bipower variation normalization. The literal user spec is BV = Σ|r_t · r_{t−1}|
# (no π/2 factor). Under iid Gaussian, that gives BV/RV → 2/π ≈ 0.637, which
# would mechanically attribute ~36% of IL to "jumps" even in calm regimes.
# We expose both: BV_RAW (user spec) and BV_BNS (Barndorff-Nielsen-Shephard
# normalized, BV/RV → 1 under no jumps). The IL decomposition uses BV_BNS
# because the proportional split only makes economic sense with that scaling.
BV_BNS_FACTOR = math.pi / 2.0


# ─── Position spec ────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class LpPosition:
    """Concentrated v3 LP position in token0_equiv units.

    L:   liquidity (human-scaled, = L_raw / 10^((d0+d1)/2))
    Pa:  lower price bound  (token0 per token1, e.g. USDC per WETH)
    Pb:  upper price bound  (same convention)
    """

    L: float
    Pa: float
    Pb: float

    def __post_init__(self) -> None:
        if not (self.Pa < self.Pb):
            raise ValueError(f"Pa must be < Pb (got Pa={self.Pa}, Pb={self.Pb})")
        if self.L <= 0:
            raise ValueError(f"L must be > 0 (got L={self.L})")


# ─── 1. Gamma series ─────────────────────────────────────────────────────────
def compute_gamma(prices: pd.Series, position: LpPosition) -> pd.DataFrame:
    """Compute Γ_t and |Γ_t| at each prices' timestamp.

    Γ_t = -L / (2 · P_t^(3/2))   if P_t ∈ [Pa, Pb]
    Γ_t = 0                       otherwise

    Returns a DataFrame indexed like `prices` with columns:
        price, gamma, abs_gamma, in_range
    """
    if not isinstance(prices, pd.Series):
        raise TypeError("prices must be a pd.Series indexed by timestamp")

    P = prices.astype(float)
    in_range = (P >= position.Pa) & (P <= position.Pb)

    # Γ in token0_per_(token0/token1)² units. With L_human and P_human, the
    # downstream IL_increment = 0.5 · |Γ| · P² · r² collapses to (V_FR/8)·r²
    # which is dimensionally token0 (USD), as expected.
    gamma = np.where(
        in_range,
        -position.L / (2.0 * np.power(P, 1.5)),
        0.0,
    )

    return pd.DataFrame(
        {
            "price": P,
            "gamma": gamma,
            "abs_gamma": np.abs(gamma),
            "in_range": in_range.astype("int8"),
        },
        index=prices.index,
    )


# ─── 2. Realized IL (gamma cost) ─────────────────────────────────────────────
def compute_realized_il(
    prices: pd.Series,
    returns: pd.Series,
    position: LpPosition,
) -> pd.DataFrame:
    """High-frequency IL increments and daily aggregate.

    IL_increment_t = 0.5 · |Γ_t| · P_t² · r_t²

    Returns DataFrame with columns: price, gamma, abs_gamma, in_range, r, il_increment.
    """
    if not prices.index.equals(returns.index):
        raise ValueError("prices and returns must share the same index")

    gamma_df = compute_gamma(prices, position)
    r = returns.astype(float).fillna(0.0)
    il_increment = 0.5 * gamma_df["abs_gamma"].to_numpy() * np.power(
        gamma_df["price"].to_numpy(), 2.0
    ) * np.power(r.to_numpy(), 2.0)

    df = gamma_df.copy()
    df["r"] = r
    df["il_increment"] = il_increment
    return df


def aggregate_il_daily(il_increments: pd.Series) -> pd.Series:
    """Sum high-frequency IL increments to a daily series."""
    if not isinstance(il_increments.index, pd.DatetimeIndex):
        raise TypeError("il_increments must have a DatetimeIndex")
    return il_increments.groupby(il_increments.index.normalize()).sum().rename("il_daily")


# ─── 3. Realized variance metrics ────────────────────────────────────────────
def compute_rv_bv_jumps(returns: pd.Series, *, normalize_bv: bool = True) -> pd.DataFrame:
    """Daily realized variance, bipower variation, and jump component.

    RV_d   = Σ r_t²       per day
    BV_d   = Σ |r_t · r_{t−1}|   per day  (× π/2 if normalize_bv=True, BNS standard)
    Jump_d = max(RV − BV, 0)

    Both BV variants are exposed (`bv_raw`, `bv_bns`); the chosen one (per
    `normalize_bv`) is also returned as `bv_daily` for downstream convenience.
    """
    if not isinstance(returns.index, pd.DatetimeIndex):
        raise TypeError("returns must have a DatetimeIndex")

    r = returns.astype(float).fillna(0.0)
    abs_r = r.abs()
    abs_r_prev = abs_r.shift(1).fillna(0.0)

    day_key = r.index.normalize()
    rv_daily = (r * r).groupby(day_key).sum().rename("rv_daily")
    bv_raw = (abs_r * abs_r_prev).groupby(day_key).sum().rename("bv_raw")
    bv_bns = (BV_BNS_FACTOR * abs_r * abs_r_prev).groupby(day_key).sum().rename("bv_bns")

    bv_daily = bv_bns if normalize_bv else bv_raw
    bv_daily = bv_daily.rename("bv_daily")

    jump_daily = (rv_daily - bv_daily).clip(lower=0.0).rename("jump_daily")

    return pd.concat([rv_daily, bv_raw, bv_bns, bv_daily, jump_daily], axis=1)


# ─── 4. IL decomposition ─────────────────────────────────────────────────────
def decompose_il(
    il_daily: pd.Series,
    rv_bv_df: pd.DataFrame,
) -> pd.DataFrame:
    """Split IL into diffusion vs jump components proportional to BV/RV and Jump/RV.

    Edge case: when RV_d == 0, both components are forced to 0 (no return = no IL).
    """
    df = pd.DataFrame(index=il_daily.index)
    df["il_daily"] = il_daily

    rv = rv_bv_df["rv_daily"].reindex(il_daily.index)
    bv = rv_bv_df["bv_daily"].reindex(il_daily.index)
    jump = rv_bv_df["jump_daily"].reindex(il_daily.index)

    df["rv_daily"] = rv
    df["bv_daily"] = bv
    df["jump_daily"] = jump

    safe_rv = rv.where(rv > 0, np.nan)
    df["bv_share"] = (bv / safe_rv).clip(lower=0.0, upper=1.0).fillna(0.0)
    df["jump_share"] = (jump / safe_rv).clip(lower=0.0, upper=1.0).fillna(0.0)

    df["il_diffusion"] = (df["il_daily"] * df["bv_share"]).fillna(0.0)
    df["il_jump"] = (df["il_daily"] * df["jump_share"]).fillna(0.0)

    return df


# ─── 5. Core metrics ─────────────────────────────────────────────────────────
def compute_core_metrics(
    fees_daily: pd.Series,
    il_daily: pd.Series,
    *,
    tvl_active_avg: float,
) -> dict:
    """FGY, GSR, σ*, and the GammaPnL series.

    All inputs are daily-grain. tvl_active_avg is pool-level avg active TVL (USD).
    σ*_daily = sqrt(8 · mean(F_daily) / TVL_active).
    σ*_annual = σ*_daily · √365.
    """
    fees, il = fees_daily.align(il_daily, join="inner")

    mean_fees = float(fees.mean())
    mean_il = float(il.mean())
    std_il = float(il.std(ddof=1))

    fgy = mean_fees / mean_il if mean_il > 0 else np.nan
    gsr = mean_fees / std_il if std_il > 0 else np.nan

    if tvl_active_avg <= 0 or mean_fees <= 0:
        sigma_star_daily = np.nan
        sigma_star_annual = np.nan
    else:
        sigma_star_daily = math.sqrt(8.0 * mean_fees / tvl_active_avg)
        sigma_star_annual = sigma_star_daily * math.sqrt(365.0)

    gamma_pnl = (fees - il).rename("gamma_pnl_daily")

    return {
        "FGY": fgy,
        "GSR": gsr,
        "mean_fees": mean_fees,
        "mean_IL": mean_il,
        "std_IL": std_il,
        "sigma_star_daily": sigma_star_daily,
        "sigma_star_annual": sigma_star_annual,
        "gamma_pnl_daily": gamma_pnl,
        "tvl_active_avg": tvl_active_avg,
    }


# ─── 6. Tail diagnostics ─────────────────────────────────────────────────────
def compute_tail_diagnostics(gamma_pnl: pd.Series, il_daily: pd.Series) -> dict:
    """Tail and skewness diagnostics."""
    pnl = gamma_pnl.dropna()
    il = il_daily.dropna()

    pct_profitable = float((pnl > 0).mean()) if len(pnl) else np.nan
    total_pnl = float(pnl.sum()) if len(pnl) else np.nan

    if len(pnl) >= 5:
        worst_5 = pnl.nsmallest(5)
        worst_5_sum = float(worst_5.sum())
        worst_5_share = (
            worst_5_sum / total_pnl
            if total_pnl != 0 and not np.isclose(total_pnl, 0)
            else np.nan
        )
    else:
        worst_5_sum = np.nan
        worst_5_share = np.nan

    il_skew = float(il.skew()) if len(il) >= 3 else np.nan

    return {
        "n_days": int(len(pnl)),
        "pct_profitable_days": pct_profitable,
        "total_gamma_pnl": total_pnl,
        "worst_5_days_sum": worst_5_sum,
        "worst_5_days_share_of_total_pnl": worst_5_share,
        "skewness_il_daily": il_skew,
    }


# ─── 7. End-to-end pipeline ──────────────────────────────────────────────────
@dataclass(frozen=True)
class GammaRiskOutput:
    """Bundle of all artefacts from the pipeline."""

    hf_df: pd.DataFrame          # high-frequency: prices, gamma, r, il_increment
    daily_df: pd.DataFrame       # daily summary: fees, il, decomposition, gamma_pnl
    summary: dict                # core metrics + tail diagnostics


def run_gamma_risk_pipeline(
    prices: pd.Series,
    returns: pd.Series,
    fees_daily: pd.Series,
    position: LpPosition,
    *,
    tvl_active_avg: float,
    normalize_bv: bool = True,
) -> GammaRiskOutput:
    """End-to-end orchestrator. All inputs aligned by timestamp / day key.

    Args:
        prices:      pd.Series of prices indexed by tz-naive datetime
        returns:     pd.Series of log returns indexed identically to prices
        fees_daily:  pd.Series of daily fees indexed by date (tz-naive datetime)
        position:    LpPosition (L, Pa, Pb)
        tvl_active_avg: pool-level average active TVL over the window (USD)
        normalize_bv: if True (default), BV uses BNS π/2 normalization

    Returns:
        GammaRiskOutput with hf_df, daily_df, and summary dict.
    """
    # 1+2: gamma + IL increments at HF
    hf_df = compute_realized_il(prices, returns, position)

    # 2 daily aggregation
    il_daily = aggregate_il_daily(hf_df["il_increment"])

    # 3: RV / BV / Jump daily
    rv_bv_df = compute_rv_bv_jumps(returns, normalize_bv=normalize_bv)

    # 4: IL decomposition
    il_decomp = decompose_il(il_daily, rv_bv_df)

    # Align daily fees to IL index
    fees_idx = pd.Series(fees_daily.values, index=pd.to_datetime(fees_daily.index).normalize())
    fees_aligned = fees_idx.reindex(il_decomp.index).rename("fees_daily")

    # 5: core metrics
    core = compute_core_metrics(fees_aligned, il_decomp["il_daily"], tvl_active_avg=tvl_active_avg)

    # 6: tail diagnostics
    tail = compute_tail_diagnostics(core["gamma_pnl_daily"], il_decomp["il_daily"])

    # Build daily output
    daily_df = il_decomp.copy()
    daily_df["fees_daily"] = fees_aligned
    daily_df["gamma_pnl_daily"] = core["gamma_pnl_daily"]

    summary = {
        "FGY": core["FGY"],
        "GSR": core["GSR"],
        "mean_IL": core["mean_IL"],
        "std_IL": core["std_IL"],
        "mean_fees": core["mean_fees"],
        "sigma_star_daily": core["sigma_star_daily"],
        "sigma_star_annual": core["sigma_star_annual"],
        "tvl_active_avg": core["tvl_active_avg"],
        "pct_profitable_days": tail["pct_profitable_days"],
        "tail_loss_contribution": tail["worst_5_days_share_of_total_pnl"],
        "worst_5_days_sum": tail["worst_5_days_sum"],
        "skewness_il_daily": tail["skewness_il_daily"],
        "total_gamma_pnl": tail["total_gamma_pnl"],
        "n_days": tail["n_days"],
    }

    return GammaRiskOutput(hf_df=hf_df, daily_df=daily_df, summary=summary)
