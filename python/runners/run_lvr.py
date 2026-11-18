"""Runner for the LVR engine."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings
from engines.lvr_engine import run_lvr, summarize_lvr_daily, validate_fee_lvr_ratio

app = typer.Typer(add_completion=False)


@app.command()
def main(
    pool: str | None = typer.Option(default=None),
    start_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    end_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    write: bool = typer.Option(default=False, help="Persist into py_lvr_per_swap / py_lvr_daily"),
    validate_range: bool = typer.Option(default=False, help="Check fee/LVR ratio against expected range"),
) -> None:
    sd = date.fromisoformat(start_date) if start_date else None
    ed = date.fromisoformat(end_date) if end_date else None
    settings = ClickHouseSettings()
    db = ClickHouseDB.from_settings(settings)
    lvr_per_swap, lvr_daily = run_lvr(
        db,
        pool=pool,
        start_date=sd,
        end_date=ed,
        write=write,
    )
    print(f"per_swap_rows={lvr_per_swap.height}")
    print(f"daily_rows={lvr_daily.height}")
    print(summarize_lvr_daily(lvr_daily))
    if validate_range:
        print(validate_fee_lvr_ratio(lvr_daily))
    db.close()


if __name__ == "__main__":
    app()
