"""
load_raw.py
-----------
Loads dimension tables (customers, plans, subscriptions) into DuckDB rds schema.

Strategy:
  - rds.customers = current state only (mirrors a real operational DB)
  - UPSERT: new records → INSERT, changed records → UPDATE, gone records → DELETE
  - No CDC metadata here — dbt snapshots handle the full SCD2 history downstream
  - Idempotent: safe to run multiple times

DuckDB auth: none needed — local embedded file, OS file permissions control access.
"""

import duckdb
import pandas as pd
from pathlib import Path
from dotenv import load_dotenv
import os
from loguru import logger

load_dotenv()

DB_PATH     = os.getenv("DB_PATH")
RAW_SCHEMA  = os.getenv("RAW_SCHEMA", "rds")
BATCHES_DIR = Path(os.getenv("BATCHES_DIR", "."))

BATCHES = [
    {"name": "batch_001", "batch_id": 1},
    {"name": "batch_002", "batch_id": 2},
    {"name": "batch_003", "batch_id": 3},
]

# Dimension tables and their primary keys
DIM_TABLES = {
    "customers":     "customer_id",
    "plans":         "plan_id",
    "subscriptions": "subscription_id",
}


def get_connection():
    con = duckdb.connect(DB_PATH)
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {RAW_SCHEMA}")
    return con


def table_exists(con, table_name):
    return con.execute(f"""
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = '{RAW_SCHEMA}' AND table_name = '{table_name}'
    """).fetchone()[0] > 0


def upsert_dim(con, batch_name, table_name, pk_col):
    csv_path   = BATCHES_DIR / batch_name / f"{table_name}.csv"
    full_table = f"{RAW_SCHEMA}.{table_name}"

    if not csv_path.exists():
        logger.warning(f"  {table_name}: not found in {batch_name}, skipping")
        return

    new_df = pd.read_csv(csv_path, low_memory=False)
    # Normalize all column names to lowercase
    new_df.columns = [c.lower().strip() for c in new_df.columns]
    logger.info(f"  {table_name}: read {len(new_df)} rows from {csv_path.name}")

    if not table_exists(con, table_name):
        # First load — create table and insert all rows
        con.execute(f"CREATE TABLE {full_table} AS SELECT * FROM new_df")
        logger.info(f"  {table_name}: created table, inserted {len(new_df)} rows")
        return

    # ── Schema evolution: add any new columns from this batch ─────────────
    existing_cols = set(
        row[0].lower() for row in
        con.execute(f"SELECT column_name FROM information_schema.columns WHERE table_schema='{RAW_SCHEMA}' AND table_name='{table_name}'").fetchall()
    )
    for col in new_df.columns:
        if col.lower() not in existing_cols:
            # Infer a safe SQL type
            dtype = new_df[col].dtype
            sql_type = "DOUBLE" if pd.api.types.is_float_dtype(dtype) else \
                       "BIGINT" if pd.api.types.is_integer_dtype(dtype) else "VARCHAR"
            con.execute(f"ALTER TABLE {full_table} ADD COLUMN {col} {sql_type}")
            logger.info(f"  {table_name}: added new column '{col}' ({sql_type}) — schema evolution")

    # ── Get current state from DB ─────────────────────────────────────────
    current_df = con.execute(f"SELECT * FROM {full_table}").df()
    current_df.columns = [c.lower().strip() for c in current_df.columns]

    current_ids = set(current_df[pk_col].astype(str))
    new_ids     = set(new_df[pk_col].astype(str))

    # ── INSERTS: new IDs not in DB ─────────────────────────────────────────
    insert_ids = new_ids - current_ids
    df_inserts = new_df[new_df[pk_col].astype(str).isin(insert_ids)]
    if not df_inserts.empty:
        con.execute(f"INSERT INTO {full_table} BY NAME SELECT * FROM df_inserts")
        logger.info(f"  {table_name}: inserted {len(df_inserts)} new records")

    # ── UPDATES: same ID, values changed ──────────────────────────────────
    common_ids   = current_ids & new_ids
    shared_cols  = [c for c in new_df.columns if c in current_df.columns]

    prev_common = current_df[current_df[pk_col].astype(str).isin(common_ids)][shared_cols].set_index(pk_col)
    new_common  = new_df[new_df[pk_col].astype(str).isin(common_ids)][shared_cols].set_index(pk_col)

    prev_aligned = prev_common.fillna("").astype(str)
    new_aligned  = new_common.fillna("").astype(str)
    changed_ids  = set(new_aligned.index[
        (new_aligned != prev_aligned.reindex(new_aligned.index, fill_value="")).any(axis=1)
    ].astype(str))

    df_updates = new_df[new_df[pk_col].astype(str).isin(changed_ids)]
    if not df_updates.empty:
        # Delete old versions then re-insert updated rows
        ids_list = ", ".join([f"'{i}'" for i in changed_ids])
        con.execute(f"DELETE FROM {full_table} WHERE CAST({pk_col} AS VARCHAR) IN ({ids_list})")
        con.execute(f"INSERT INTO {full_table} BY NAME SELECT * FROM df_updates")
        logger.info(f"  {table_name}: updated {len(df_updates)} records")

    # ── DELETES: IDs in DB but gone from new batch ─────────────────────────
    delete_ids = current_ids - new_ids
    if delete_ids:
        ids_list = ", ".join([f"'{i}'" for i in delete_ids])
        con.execute(f"DELETE FROM {full_table} WHERE CAST({pk_col} AS VARCHAR) IN ({ids_list})")
        logger.info(f"  {table_name}: deleted {len(delete_ids)} records (not present in new batch)")

    if not insert_ids and not changed_ids and not delete_ids:
        logger.info(f"  {table_name}: no changes detected")


def run():
    logger.info(f"Connecting to DuckDB: {DB_PATH}")
    con = get_connection()

    for batch in BATCHES:
        batch_name = batch["name"]
        batch_dir  = BATCHES_DIR / batch_name

        if not batch_dir.exists():
            logger.warning(f"Batch dir not found: {batch_dir}, skipping")
            continue

        logger.info(f"\n{'─'*50}")
        logger.info(f"Processing {batch_name}")
        logger.info(f"{'─'*50}")

        for table_name, pk_col in DIM_TABLES.items():
            upsert_dim(con, batch_name, table_name, pk_col)

    # ── Summary ───────────────────────────────────────────────────────────
    logger.info(f"\n{'='*50}")
    logger.info("RDS schema — current state:")
    logger.info(f"{'='*50}")

    tables = con.execute(f"""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = '{RAW_SCHEMA}'
        ORDER BY table_name
    """).fetchall()

    for (tbl,) in tables:
        count = con.execute(f"SELECT COUNT(*) FROM {RAW_SCHEMA}.{tbl}").fetchone()[0]
        logger.info(f"  {tbl:<20} {count:>5} rows")

    con.close()
    logger.info("\nDone.")


if __name__ == "__main__":
    run()
