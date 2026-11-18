"""Runner for the EVC volatility surface module."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from analytics.vol_surface import build_vol_surface
from core.db import ClickHouseDB, ClickHouseSettings

app = typer.Typer(add_completion=False)


@app.command()
def main(
    pool: str | None = typer.Option(default=None),
    start_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    end_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    bucket_width: float = typer.Option(default=0.05, help="Log-moneyness bucket width"),
    cross_section_window: int = typer.Option(default=3, help="Rolling mean window over neighbor buckets"),
    temporal_halflife_days: int = typer.Option(default=3, help="EWMA half-life in days"),
    write: bool = typer.Option(default=False, help="Persist into py_vol_surface_daily"),
) -> None:
    sd = date.fromisoformat(start_date) if start_date else None
    ed = date.fromisoformat(end_date) if end_date else None
    db = ClickHouseDB.from_settings(ClickHouseSettings())
    result = build_vol_surface(
        db,
        pool=pool,
        start_date=sd,
        end_date=ed,
        bucket_width=bucket_width,
        cross_section_window=cross_section_window,
        temporal_halflife_days=temporal_halflife_days,
        write=write,
    )
    print(f"rows={result.height}")
    if not result.is_empty():
        print(f"pools={result.get_column('pool').n_unique()}")
        print(f"days={result.get_column('day').n_unique()}")
        print(f"buckets={result.get_column('moneyness_bucket').n_unique()}")
    db.close()


if __name__ == "__main__":
    app()
