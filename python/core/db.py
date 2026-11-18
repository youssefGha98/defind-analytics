"""ClickHouse read/write helpers for the new Python analytics layer."""

from __future__ import annotations

import clickhouse_connect
import polars as pl
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ClickHouseSettings(BaseSettings):
    host: str = Field(default="localhost", alias="CLICKHOUSE_HOST")
    port: int = Field(default=8123, alias="CLICKHOUSE_PORT")
    database: str = Field(default="defind", alias="CLICKHOUSE_DATABASE")
    user: str = Field(default="default", alias="CLICKHOUSE_USER")
    password: str = Field(default="", alias="CLICKHOUSE_PASSWORD")
    secure: bool = Field(default=False, alias="CLICKHOUSE_SECURE")

    model_config = SettingsConfigDict(
        populate_by_name=True,
        case_sensitive=False,
        extra="ignore",
    )


class ClickHouseDB:
    """Minimal ClickHouse wrapper returning Polars frames."""

    def __init__(
        self,
        host: str,
        port: int,
        database: str,
        user: str,
        password: str,
        *,
        secure: bool = False,
    ) -> None:
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.secure = secure
        self._client = clickhouse_connect.get_client(
            host=host,
            port=port,
            database=database,
            username=user,
            password=password,
            secure=secure,
            # Explicit timeouts so a half-closed socket raises instead of
            # blocking forever in epoll_wait. The kernel hangs we hit before
            # were caused by stale CLOSE_WAIT sockets and no read timeout.
            connect_timeout=10,        # TCP handshake
            send_receive_timeout=180,  # max query duration before raising
        )

    @classmethod
    def from_settings(cls, settings: ClickHouseSettings | None = None) -> "ClickHouseDB":
        resolved = settings or ClickHouseSettings()
        return cls(
            host=resolved.host,
            port=resolved.port,
            database=resolved.database,
            user=resolved.user,
            password=resolved.password,
            secure=resolved.secure,
        )

    def close(self) -> None:
        self._client.close()

    def qualify(self, table_name: str) -> str:
        if "." in table_name:
            return table_name
        return f"{self.database}.{table_name}"

    def ping(self) -> bool:
        return bool(self._client.ping())

    def table_exists(self, table_name: str) -> bool:
        qualified = self.qualify(table_name)
        database, name = qualified.split(".", 1)
        result = self.read_query(
            "SELECT count() AS cnt "
            "FROM system.tables "
            f"WHERE database = '{database}' AND name = '{name}'"
        )
        if result.is_empty() or "cnt" not in result.columns:
            return False
        return bool(int(result.item(0, "cnt")))

    def delete_where(self, table_name: str, where: str) -> None:
        self._client.command(f"ALTER TABLE {self.qualify(table_name)} DELETE WHERE {where}")

    def read_query(self, query: str) -> pl.DataFrame:
        result = self._client.query(query)
        rows = list(result.named_results())
        if not rows:
            if hasattr(result, "column_names") and result.column_names:
                return pl.DataFrame(
                    schema={name: pl.Null for name in result.column_names}
                )
            return pl.DataFrame()
        return pl.DataFrame(rows, infer_schema_length=len(rows))

    def read_table(
        self,
        table_name: str,
        columns: list[str] | None = None,
        where: str | None = None,
    ) -> pl.DataFrame:
        selected = ", ".join(columns) if columns else "*"
        query = f"SELECT {selected} FROM {self.qualify(table_name)}"
        if where:
            query = f"{query} WHERE {where}"
        return self.read_query(query)

    def write_table(
        self,
        df: pl.DataFrame,
        table_name: str,
        *,
        create_if_missing: bool = True,
        engine: str = "MergeTree",
        order_by: list[str] | None = None,
    ) -> int:
        target = self.qualify(table_name)
        if create_if_missing:
            self._ensure_table(target, df, engine=engine, order_by=order_by)
        if df.is_empty():
            return 0
        self._client.insert_arrow(table_name, df.to_arrow(), database=self.database)
        return df.height

    def _ensure_table(
        self,
        qualified_table_name: str,
        df: pl.DataFrame,
        *,
        engine: str,
        order_by: list[str] | None,
    ) -> None:
        columns = self._columns_ddl(df.schema)
        order = order_by or [next(iter(df.schema.keys()), "tuple()")]
        order_expr = "tuple()" if order == ["tuple()"] else f"({', '.join(order)})"
        sql = (
            f"CREATE TABLE IF NOT EXISTS {qualified_table_name} ({columns}) "
            f"ENGINE = {engine} ORDER BY {order_expr}"
        )
        self._client.command(sql)
        self._sync_missing_columns(qualified_table_name, df.schema)

    def _sync_missing_columns(
        self,
        qualified_table_name: str,
        schema: dict[str, pl.DataType],
    ) -> None:
        described = self.read_query(f"DESCRIBE TABLE {qualified_table_name}")
        existing = set(described.get_column("name").to_list()) if not described.is_empty() else set()
        for name, dtype in schema.items():
            if name in existing:
                continue
            self._client.command(
                f"ALTER TABLE {qualified_table_name} "
                f"ADD COLUMN IF NOT EXISTS {name} {self._map_dtype(dtype)}"
            )

    @staticmethod
    def _columns_ddl(schema: dict[str, pl.DataType]) -> str:
        return ", ".join(
            f"{name} {ClickHouseDB._map_dtype(dtype)}" for name, dtype in schema.items()
        )

    @staticmethod
    def _map_dtype(dtype: pl.DataType) -> str:
        mapping: dict[pl.DataType, str] = {
            pl.Int8: "Int8",
            pl.Int16: "Int16",
            pl.Int32: "Int32",
            pl.Int64: "Int64",
            pl.UInt8: "UInt8",
            pl.UInt16: "UInt16",
            pl.UInt32: "UInt32",
            pl.UInt64: "UInt64",
            pl.Float32: "Float32",
            pl.Float64: "Float64",
            pl.Boolean: "Bool",
            pl.String: "String",
            pl.Utf8: "String",
            pl.Date: "Date",
            pl.Null: "Nullable(String)",
        }
        if dtype in mapping:
            return mapping[dtype]
        if isinstance(dtype, pl.Datetime):
            return "DateTime64(6)"
        if isinstance(dtype, pl.Decimal):
            precision = dtype.precision or 38
            scale = dtype.scale or 18
            return f"Decimal({precision}, {scale})"
        raise TypeError(f"unsupported Polars dtype for ClickHouse DDL: {dtype!r}")
