# NexusFlow Analytics — Take-Home Exercise

End-to-end analytics project: raw CSV ingestion → dbt semantic layer → Streamlit dashboard with role-based access control.

---

## Quick start

### 1. Prerequisites

| Tool | Version |
|---|---|
| Python | 3.11+ |
| pip | latest |
| git | any |

No database server needed — everything runs on **DuckDB** (embedded, file-based).

---

### 2. Clone the repo

```bash
git clone https://github.com/giltruman1906-byte/stampli-project.git
cd stampli-project
git checkout dev
```

---

### 3. Create a virtual environment and install dependencies

```bash
python -m venv .venv

# macOS / Linux
source .venv/bin/activate

# Windows
.venv\Scripts\activate

pip install -r requirements.txt
```

---

### 4. Build the database

The `.duckdb` file is not committed (binary). Build it from the source CSV batches already in the repo:

**Step 1 — Load raw data (ETL)**
```bash
python etl/load_raw.py
```
This reads `batch_001/`, `batch_002/`, `batch_003/` and writes `nexusflow.duckdb`.
Expected output: `✓ Load complete — X rows across Y tables`

**Step 2 — Run dbt (semantic layer)**
```bash
cd nexusflow
dbt build
cd ..
```
Expected output: `Completed successfully — PASS=26 WARN=0 ERROR=0`

---

### 5. Run the dashboard

```bash
streamlit run dashboard/app.py
```

The dashboard opens automatically at:

**`http://localhost:8501`**

---

## Login credentials

| Username | Password | Role | Access |
|---|---|---|---|
| `admin` | `admin123` | Admin | All tabs + raw data tab + CSV export |
| `analyst` | `analyst123` | Analyst | Revenue, Customers, Support, Product + CSV export |
| `mgr_na` | `na123` | Regional Manager (NA) | Revenue, Customers, Support, Product — NA region only |
| `mgr_emea` | `emea123` | Regional Manager (EMEA) | Revenue, Customers, Support, Product — EMEA region only |
| `mgr_apac` | `apac123` | Regional Manager (APAC) | Revenue, Customers, Support, Product — APAC region only |
| `viewer` | `viewer123` | Viewer | Revenue and Customers tabs only |

---

## Full tech stack

| Layer | Technology |
|---|---|
| Storage | DuckDB 1.x (embedded columnar database) |
| ETL | Python 3.11 + pandas — `etl/load_raw.py` |
| Transformation | dbt-core 1.8 + dbt-duckdb adapter |
| Dashboard | Streamlit 1.36 |
| Charts | Plotly 5 |
| Data modelling | dbt (staging → core → intermediate → marts) |
| Auth / RBAC | Session-state login, role-based tab + region filtering |

---

## Project structure

```
.
├── batch_001/          # Raw CSV data — initial load
├── batch_002/          # Raw CSV data — second batch (amendments, adjustments)
├── batch_003/          # Raw CSV data — corrections + late events
├── etl/
│   └── load_raw.py     # Ingests all batches into nexusflow.duckdb
├── nexusflow/          # dbt project
│   ├── models/
│   │   ├── staging/    # 10 models — type casting, ID normalisation
│   │   ├── core/       # 6 fact tables + 3 dimension tables
│   │   ├── intermediate/ # 3 models — usage, support, financial signals per customer
│   │   └── marts/      # 4 models — MRR, NRR, customer health score, support summary
│   └── macros/         # finance.sql, utils.sql, duckdb_udfs.sql
├── dashboard/
│   ├── app.py          # Streamlit app (4 tabs)
│   ├── db.py           # All DuckDB query functions
│   └── auth.py         # Users, roles, permissions
├── decision_log.md     # Design decisions and known limitations
└── requirements.txt
```

---

## Dashboard tabs

| Tab | What it shows |
|---|---|
| **Revenue** | ARR by region, MRR waterfall (latest month), NRR waterfall table Jan–Mar, amendment breakdown by type |
| **Customers** | Health score table (0–100 composite), risk tier KPIs, MRR at risk, model weights explained |
| **Support** | Ticket volume + resolution time + satisfaction by category (region filter), open tickets with days open |
| **Product** | Feature adoption by month, engagement vs MRR scatter, post-ticket recovery, usage risk signals |

---

## Rebuild from scratch (full sequence)

```bash
# 1. Clone
git clone https://github.com/giltruman1906-byte/stampli-project.git
cd stampli-project && git checkout dev

# 2. Environment
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 3. Database
python etl/load_raw.py
cd nexusflow && dbt build && cd ..

# 4. Dashboard
streamlit run dashboard/app.py
# → open http://localhost:8501
```

Total setup time: ~3 minutes.
