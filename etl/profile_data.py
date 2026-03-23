"""
Data profiling script — runs across all 3 batches and reports:
- Row counts
- Null rates
- Duplicate keys
- Customer ID format distribution
- Date range coverage
- Cross-file join integrity
"""

import pandas as pd
import os
from pathlib import Path

BASE = Path(__file__).parent.parent
BATCHES = ["batch_001", "batch_002", "batch_003"]
FILES = [
    "customers", "plans", "subscriptions", "invoices",
    "payments", "usage_events", "support_tickets", "product_events",
    "adjustments", "contract_amendments", "corrections", "late_usage_jan"
]

# ─── helpers ──────────────────────────────────────────────────────────────────

def load(batch, name):
    path = BASE / batch / f"{name}.csv"
    if not path.exists():
        return None
    return pd.read_csv(path, low_memory=False)

def sep(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print('='*60)

def subsep(title):
    print(f"\n  --- {title} ---")

# ─── 1. Row counts per batch ───────────────────────────────────────────────────

sep("1. ROW COUNTS PER BATCH")
for batch in BATCHES:
    print(f"\n  {batch}:")
    for name in FILES:
        df = load(batch, name)
        if df is not None:
            print(f"    {name:<25} {len(df):>6} rows  |  {len(df.columns)} cols")

# ─── 2. Null rates ─────────────────────────────────────────────────────────────

sep("2. NULL RATES (columns with >0% nulls)")
for name in ["customers", "subscriptions", "invoices", "payments", "usage_events"]:
    df = load("batch_001", name)
    if df is None:
        continue
    null_rates = (df.isnull().mean() * 100).round(1)
    has_nulls = null_rates[null_rates > 0]
    if has_nulls.empty:
        print(f"\n  {name}: no nulls")
    else:
        print(f"\n  {name}:")
        for col, pct in has_nulls.items():
            print(f"    {col:<30} {pct}% null")

# ─── 3. Customer ID format analysis ───────────────────────────────────────────

sep("3. CUSTOMER ID FORMATS")
for batch in BATCHES:
    df = load(batch, "customers")
    if df is None:
        continue
    ids = df["customer_id"].dropna().astype(str)

    def classify(cid):
        if cid.upper().startswith("CUST-"):
            return "CUST-001"
        elif cid.lower().startswith("cust_"):
            return "cust_1234"
        elif cid.upper().startswith("C") and cid[1:].isdigit():
            return "C001"
        else:
            return f"other: {cid[:10]}"

    formats = ids.apply(classify).value_counts()
    print(f"\n  {batch}:")
    for fmt, cnt in formats.items():
        print(f"    {fmt:<20} {cnt} records")

# ─── 4. Duplicate key check ────────────────────────────────────────────────────

sep("4. DUPLICATE PRIMARY KEYS")
key_map = {
    "customers":           "customer_id",
    "subscriptions":       "subscription_id",
    "invoices":            "invoice_id",
    "payments":            "payment_id",
    "usage_events":        "event_id",
    "support_tickets":     "ticket_id",
    "plans":               "plan_id",
}
for batch in BATCHES:
    print(f"\n  {batch}:")
    for name, key in key_map.items():
        df = load(batch, name)
        if df is None or key not in df.columns:
            continue
        dupes = df[key].duplicated().sum()
        status = f"  *** {dupes} DUPLICATES ***" if dupes > 0 else "  ok"
        print(f"    {name:<25} {key:<25} {status}")

# ─── 5. Cross-file referential integrity ──────────────────────────────────────

sep("5. REFERENTIAL INTEGRITY (batch_001)")
customers = load("batch_001", "customers")
subscriptions = load("batch_001", "subscriptions")
invoices = load("batch_001", "invoices")
payments = load("batch_001", "payments")
usage = load("batch_001", "usage_events")
tickets = load("batch_001", "support_tickets")

cust_ids = set(customers["customer_id"].dropna().astype(str))

checks = [
    ("subscriptions",   subscriptions,  "customer_id"),
    ("invoices",        invoices,       "customer_id"),
    ("payments",        payments,       "customer_id"),
    ("usage_events",    usage,          "customer_id"),
    ("support_tickets", tickets,        "customer_id"),
]

for name, df, col in checks:
    if df is None or col not in df.columns:
        continue
    refs = set(df[col].dropna().astype(str))
    orphans = refs - cust_ids
    pct = round(len(orphans) / len(refs) * 100, 1) if refs else 0
    flag = "  *** ORPHANS ***" if orphans else "  ok"
    print(f"  {name:<25} {len(orphans)} orphan customer_ids ({pct}%){flag}")

# ─── 6. Subscription overlap check ───────────────────────────────────────────

sep("6. OVERLAPPING SUBSCRIPTION DATES (batch_001)")
subs = load("batch_001", "subscriptions")
subs["start_date"] = pd.to_datetime(subs["start_date"], errors="coerce")
subs["end_date"]   = pd.to_datetime(subs["end_date"],   errors="coerce")

overlap_count = 0
for cust, grp in subs.groupby("customer_id"):
    active = grp[grp["end_date"].isna() | (grp["end_date"] > grp["start_date"])]
    if len(active) > 1:
        overlap_count += 1

print(f"  Customers with multiple active subscriptions: {overlap_count}")

# ─── 7. Date range coverage ───────────────────────────────────────────────────

sep("7. DATE RANGE COVERAGE")
for batch in BATCHES:
    inv = load(batch, "invoices")
    if inv is None:
        continue
    inv["invoice_date"] = pd.to_datetime(inv["invoice_date"], errors="coerce")
    print(f"  {batch} invoices: {inv['invoice_date'].min().date()} → {inv['invoice_date'].max().date()}")

# ─── 8. Status value distributions ───────────────────────────────────────────

sep("8. STATUS VALUE DISTRIBUTIONS (batch_001)")
checks = [
    ("subscriptions",   "status"),
    ("payments",        "status"),
    ("support_tickets", "status"),
]
for name, col in checks:
    df = load("batch_001", name)
    if df is None or col not in df.columns:
        continue
    print(f"\n  {name}.{col}:")
    for val, cnt in df[col].value_counts(dropna=False).items():
        print(f"    {str(val):<20} {cnt}")

# ─── 9. Batch-over-batch customer ID consistency ──────────────────────────────

sep("9. CUSTOMER ID CONSISTENCY ACROSS BATCHES")
sets = {}
for batch in BATCHES:
    df = load(batch, "customers")
    if df is not None:
        sets[batch] = set(df["customer_id"].dropna().astype(str))

b1, b2, b3 = sets.get("batch_001", set()), sets.get("batch_002", set()), sets.get("batch_003", set())
print(f"  batch_001 customers:           {len(b1)}")
print(f"  batch_002 customers:           {len(b2)}")
print(f"  batch_003 customers:           {len(b3)}")
print(f"  New in batch_002 vs batch_001: {len(b2 - b1)}")
print(f"  New in batch_003 vs batch_002: {len(b3 - b2)}")
print(f"  Dropped batch_001→002:         {len(b1 - b2)}")
print(f"  Dropped batch_002→003:         {len(b2 - b3)}")

print("\n" + "="*60)
print("  Profiling complete.")
print("="*60 + "\n")
