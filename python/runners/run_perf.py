"""Runner for the NFPM performance engine."""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path

import typer

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.db import ClickHouseDB, ClickHouseSettings
from engines.perf_engine import (
    compare_terminal_values_to_dbt,
    run_position_performance,
    summarize_terminal_comparison,
)

app = typer.Typer(add_completion=False)


@app.command()
def main(
    pool: str | None = typer.Option(default=None),
    token_ids: str | None = typer.Option(default=None, help="Comma-separated token ids"),
    start_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    end_date: str | None = typer.Option(default=None, help="YYYY-MM-DD"),
    write: bool = typer.Option(default=False, help="Persist into py_position_performance_daily"),
    validate_terminal: bool = typer.Option(default=False, help="Compare terminal values to DBT mart"),
) -> None:
    sd = date.fromisoformat(start_date) if start_date else None
    ed = date.fromisoformat(end_date) if end_date else None
    settings = ClickHouseSettings()
    db = ClickHouseDB.from_settings(settings)
    ids = [int(part.strip()) for part in token_ids.split(",")] if token_ids else None
    perf = run_position_performance(
        db,
        pool=pool,
        token_ids=ids,
        start_date=sd,
        end_date=ed,
        write=write,
    )
    print(f"rows={perf.height}")
    if validate_terminal:
        comparison = compare_terminal_values_to_dbt(
            db,
            perf,
            pool=pool,
            token_ids=ids,
        )
        print(summarize_terminal_comparison(comparison))
    db.close()


if __name__ == "__main__":
    app()
