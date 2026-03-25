"""
load_raw.py
-----------
Loads all CSV batches into DuckDB rds schema.

Two loading strategies:
  1. Dimensions (customers, plans, subscriptions)
     → UPSERT: insert new, update changed, delete removed
     → rds always reflects current state
     → dbt snapshot handles SCD2 history downstream

  2. Facts (invoices, payments, usage_events, etc.)
     → Incremental append: new batch rows appended, never deleted
     → Idempotent: batch_id tracked to prevent duplicates on re-run
     → Special files: corrections.csv patches existing rows

DuckDB auth: none needed — local file, OS permissions control access.
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

# Dimension tables: UPSERT strategy
DIM_TABLES = {
    "customers":     "customer_id",
    "plans":         "plan_id",
    "subscriptions": "subscription_id",
}

# Fact tables: incremental append strategy + their primary keys
FACT_TABLES = {
    "invoices":            "invoice_id",
    "payments":            "payment_id",
    "usage_events":        "event_id",
    "support_tickets":     "ticket_id",
    "product_events":      "event_id",
    "adjustments":         "adjustment_id",
    "contract_amendments": "amendment_id",
    "late_usage_jan":      "event_id",   # late-arriving facts for Jan
}

# Special: corrections.csv patches existing rows across tables
CORRECTIONS_FILE = "corrections"


# ─── helpers ──────────────────────────────────────────────────────────────────

def get_connection():
    con = duckdb.connect(DB_PATH)
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {RAW_SCHEMA}")
    return con


def table_exists(con, table_name):
    return con.execute(f"""
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = '{RAW_SCHEMA}' AND table_name = '{table_name}'
    """).fetchone()[0] > 0


def evolve_schema(con, table_name, new_df):
    """Add any new columns from new_df that don't exist in the table yet."""
    existing_cols = set(
        row[0].lower() for row in con.execute(f"""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = '{RAW_SCHEMA}' AND table_name = '{table_name}'
        """).fetchall()
    )
    for col in new_df.columns:
        if col.lower() not in existing_cols:
            dtype = new_df[col].dtype
            # Default to VARCHAR for safety — avoids type conflicts across batches
            sql_type = "BIGINT"  if pd.api.types.is_integer_dtype(dtype) else \
                       "BOOLEAN" if pd.api.types.is_bool_dtype(dtype)    else "VARCHAR"
            con.execute(f"ALTER TABLE {RAW_SCHEMA}.{table_name} ADD COLUMN {col} {sql_type}")
            logger.info(f"    schema evolution: added column '{col}' ({sql_type})")


# ─── 1. DIMENSION UPSERT ──────────────────────────────────────────────────────

def upsert_dim(con, batch_name, table_name, pk_col):
    csv_path   = BATCHES_DIR / batch_name / f"{table_name}.csv"
    full_table = f"{RAW_SCHEMA}.{table_name}"

    if not csv_path.exists():
        return

    new_df = pd.read_csv(csv_path, low_memory=False)
    new_df.columns = [c.lower().strip() for c in new_df.columns]

    if not table_exists(con, table_name):
        con.execute(f"CREATE TABLE {full_table} AS SELECT * FROM new_df")
        logger.info(f"  {table_name}: created, inserted {len(new_df)} rows")
        return

    evolve_schema(con, table_name, new_df)

    current_df = con.execute(f"SELECT * FROM {full_table}").df()
    current_df.columns = [c.lower().strip() for c in current_df.columns]

    current_ids = set(current_df[pk_col].astype(str))
    new_ids     = set(new_df[pk_col].astype(str))

    # Inserts
    insert_ids = new_ids - current_ids
    df_inserts = new_df[new_df[pk_col].astype(str).isin(insert_ids)]
    if not df_inserts.empty:
        con.execute(f"INSERT INTO {full_table} BY NAME SELECT * FROM df_inserts")

    # Updates
    shared_cols  = [c for c in new_df.columns if c in current_df.columns]
    common_ids   = current_ids & new_ids
    prev_common  = current_df[current_df[pk_col].astype(str).isin(common_ids)][shared_cols].set_index(pk_col)
    new_common   = new_df[new_df[pk_col].astype(str).isin(common_ids)][shared_cols].set_index(pk_col)
    prev_aligned = prev_common.fillna("").astype(str)
    new_aligned  = new_common.fillna("").astype(str)
    changed_ids  = set(new_aligned.index[
        (new_aligned != prev_aligned.reindex(new_aligned.index, fill_value="")).any(axis=1)
    ].astype(str))

    df_updates = new_df[new_df[pk_col].astype(str).isin(changed_ids)]
    if not df_updates.empty:
        ids_list = ", ".join([f"'{i}'" for i in changed_ids])
        con.execute(f"DELETE FROM {full_table} WHERE CAST({pk_col} AS VARCHAR) IN ({ids_list})")
        con.execute(f"INSERT INTO {full_table} BY NAME SELECT * FROM df_updates")

    # Deletes
    delete_ids = current_ids - new_ids
    if delete_ids:
        ids_list = ", ".join([f"'{i}'" for i in delete_ids])
        con.execute(f"DELETE FROM {full_table} WHERE CAST({pk_col} AS VARCHAR) IN ({ids_list})")

    logger.info(f"  {table_name}: +{len(df_inserts)} inserts | ~{len(df_updates)} updates | -{len(delete_ids)} deletes")


# ─── 2. FACT INCREMENTAL APPEND ───────────────────────────────────────────────

def load_fact_incremental(con, batch_name, batch_id, table_name, pk_col):
    csv_path   = BATCHES_DIR / batch_name / f"{table_name}.csv"
    full_table = f"{RAW_SCHEMA}.{table_name}"

    if not csv_path.exists():
        return

    # Read everything as string — raw layer stores raw values, staging handles typing
    new_df = pd.read_csv(csv_path, dtype=str, low_memory=False)
    new_df.columns = [c.lower().strip() for c in new_df.columns]
    new_df["_batch_id"] = str(batch_id)

    if not table_exists(con, table_name):
        # Explicitly create all columns as VARCHAR to prevent type inference issues
        # across batches (e.g. a column null in batch_002 gets typed, then has strings in batch_003)
        col_defs = ", ".join([f'"{col}" VARCHAR' for col in new_df.columns])
        con.execute(f"CREATE TABLE {full_table} ({col_defs})")
        con.execute(f"INSERT INTO {full_table} SELECT * FROM new_df")
        logger.info(f"  {table_name}: created, inserted {len(new_df)} rows")
        return

    evolve_schema(con, table_name, new_df)

    # Idempotency: remove this batch's rows then re-insert
    existing_batch = con.execute(
        f"SELECT COUNT(*) FROM {full_table} WHERE _batch_id = {batch_id}"
    ).fetchone()[0]

    if existing_batch > 0:
        con.execute(f"DELETE FROM {full_table} WHERE _batch_id = {batch_id}")
        logger.info(f"  {table_name}: removed {existing_batch} rows for batch_id={batch_id} (idempotent re-run)")

    con.execute(f"INSERT INTO {full_table} BY NAME SELECT * FROM new_df")
    logger.info(f"  {table_name}: appended {len(new_df)} rows (batch_id={batch_id})")


# ─── 3. CORRECTIONS PATCH ─────────────────────────────────────────────────────

def apply_corrections(con, batch_name, batch_id):
    """
    corrections.csv patches previously loaded rows in any fact table.
    Expected columns: target_table, target_id_col, target_id, field, old_value, new_value
    """
    csv_path = BATCHES_DIR / batch_name / f"{CORRECTIONS_FILE}.csv"
    if not csv_path.exists():
        return

    corrections = pd.read_csv(csv_path, low_memory=False)
    corrections.columns = [c.lower().strip() for c in corrections.columns]
    logger.info(f"  corrections: applying {len(corrections)} patches from {batch_name}")

    # Map entity_type → (table_name, pk_column)
    entity_map = {
        "invoice":           ("invoices",            "invoice_id"),
        "payment":           ("payments",            "payment_id"),
        "customer":          ("customers",           "customer_id"),
        "subscription":      ("subscriptions",       "subscription_id"),
        "usage_event":       ("usage_events",        "event_id"),
        "support_ticket":    ("support_tickets",     "ticket_id"),
    }

    applied = 0
    for _, row in corrections.iterrows():
        entity_type = str(row.get("entity_type", "")).strip().lower()
        entity_id   = row.get("entity_id")
        field       = row.get("field_corrected")
        new_val     = row.get("new_value")

        if entity_type not in entity_map:
            logger.warning(f"  corrections: unknown entity_type '{entity_type}', skipping")
            continue

        table_name, pk_col = entity_map[entity_type]
        full_table = f"{RAW_SCHEMA}.{table_name}"

        if not table_exists(con, table_name):
            logger.warning(f"  corrections: table '{table_name}' not found, skipping")
            continue

        val_expr = f"'{new_val}'" if pd.notna(new_val) else "NULL"
        con.execute(f"""
            UPDATE {full_table}
            SET {field} = {val_expr}
            WHERE {pk_col} = '{entity_id}'
        """)
        applied += 1

    logger.info(f"  corrections: applied {applied} patches")


# ─── main ─────────────────────────────────────────────────────────────────────

def run():
    logger.info(f"Connecting to DuckDB: {DB_PATH}")
    con = get_connection()

    for batch in BATCHES:
        batch_name = batch["name"]
        batch_id   = batch["batch_id"]
        batch_dir  = BATCHES_DIR / batch_name

        if not batch_dir.exists():
            logger.warning(f"Batch dir not found: {batch_dir}, skipping")
            continue

        logger.info(f"\n{'─'*55}")
        logger.info(f"  {batch_name}  (batch_id={batch_id})")
        logger.info(f"{'─'*55}")

        # Dimensions first
        for table_name, pk_col in DIM_TABLES.items():
            upsert_dim(con, batch_name, table_name, pk_col)

        # Facts incremental
        for table_name, pk_col in FACT_TABLES.items():
            load_fact_incremental(con, batch_name, batch_id, table_name, pk_col)

        # Corrections patch (batch_003 only, but handled generically)
        apply_corrections(con, batch_name, batch_id)

    # ── Summary ───────────────────────────────────────────────────────────
    logger.info(f"\n{'='*55}")
    logger.info("RDS schema — final state:")
    logger.info(f"{'='*55}")

    tables = con.execute(f"""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = '{RAW_SCHEMA}'
        ORDER BY table_name
    """).fetchall()

    for (tbl,) in tables:
        count = con.execute(f"SELECT COUNT(*) FROM {RAW_SCHEMA}.{tbl}").fetchone()[0]
        # Show batch breakdown if _batch_id column exists
        has_batch = con.execute(f"""
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema='{RAW_SCHEMA}' AND table_name='{tbl}' AND column_name='_batch_id'
        """).fetchone()[0]

        if has_batch:
            by_batch = con.execute(f"""
                SELECT _batch_id, COUNT(*) FROM {RAW_SCHEMA}.{tbl}
                GROUP BY _batch_id ORDER BY _batch_id
            """).fetchall()
            batch_str = "  |  ".join([f"b{b}:{c}" for b, c in by_batch])
            logger.info(f"  {tbl:<25} {count:>6} rows  ({batch_str})")
        else:
            logger.info(f"  {tbl:<25} {count:>6} rows")

    con.close()
    logger.info("\nDone.")


if __name__ == "__main__":
    run()
