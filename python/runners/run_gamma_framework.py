"""Runner for the three-layer Gamma Framework engine."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings
from engines.gamma_framework import LpPosition, run_gamma_framework

app = typer.Typer(add_completion=False)


@app.command()
def main(
    pool: str = typer.Option(..., help="Pool address"),
    start_date: str = typer.Option(..., help="YYYY-MM-DD"),
    end_date: str = typer.Option(..., help="YYYY-MM-DD"),
    L: float = typer.Option(..., help="Position L_human (synthetic)"),
    Pa: float = typer.Option(..., help="Position lower price"),
    Pb: float = typer.Option(..., help="Position upper price"),
    label: str = typer.Option("synthetic_wide"),
    share: float = typer.Option(1.0, help="Position share of pool active L"),
    asset: str = typer.Option("ETH"),
    write: bool = typer.Option(False),
) -> None:
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    position = LpPosition(L=L, Pa=Pa, Pb=Pb, label=label)
    out = run_gamma_framework(
        db,
        pool=pool,
        position=position,
        start_date=date.fromisoformat(start_date),
        end_date=date.fromisoformat(end_date),
        asset_label=asset,
        position_share=share,
        write=write,
    )
    print(f"vol_features:      {out.vol_features.shape}")
    print(f"pool_features:     {out.pool_features.shape}")
    print(f"position_features: {out.position_features.shape}")
    if not out.position_features.empty:
        last = out.position_features.iloc[-1]
        print(f"\nLast day ({last['date']}):")
        print(f"  fees_position_d:        ${last['fees_position_usd_daily']:>12,.0f}")
        print(f"  gamma_cost_realized_d:  ${last['gamma_cost_realized_usd_daily']:>12,.0f}")
        print(f"  diffusion_gc_d:         ${last['diffusion_gamma_cost_usd_daily']:>12,.0f}")
        print(f"  jump_gc_d:              ${last['jump_gamma_cost_usd_daily']:>12,.0f}")
        print(f"  gamma_pnl_d:            ${last['gamma_pnl_usd_daily']:>12,.0f}")
        print(f"  FGY (window):           {last['fee_to_mean_gamma_cost_ratio']:>12.3f}")
        print(f"  GSR (window):           {last['fee_to_gamma_cost_volatility_ratio']:>12.3f}")
    db.close()


if __name__ == "__main__":
    app()
