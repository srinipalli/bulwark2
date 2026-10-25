# Bulwark: Vulnerability Patch Management Platform

Bulwark takes vulnerability scan results and turns them into patches applied to servers, with approvals and an audit trail along the way:

```
Scan workbook → Vulnerabilities → Incidents → Plan (approved Solutions) → Approval → Execution on assets → Resolved
```

This folder (`C:\SystemPatcher`) contains **four independent projects** that share **one PostgreSQL database** and **one Kafka topic**:

| Project | Type | Tech | Role |
|---|---|---|---|
| [bulwark-api](bulwark-api/) | REST API + job worker | Python 3.11+, FastAPI, async SQLAlchemy, Alembic | The core system: owns the schema, business rules, approvals and patch execution |
| [bulwark-ui](bulwark-ui/) | Web front end | React 18, Vite, React Router | Screens for analysts, approvers and operators |
| [bulwark-scan-ingestor](bulwark-scan-ingestor/) | Batch / watch job | Python, psycopg 3, openpyxl, confluent-kafka | Loads scanner `.xlsx` files, creates incidents, publishes them to Kafka |
| [bulwark-inc-planner-solution-recommender](bulwark-inc-planner-solution-recommender/) | Kafka consumer | Python, psycopg 3, pgvector, Google Gemini | Finds similar past incidents and has an AI draft a remediation plan |

---

## 1. Architecture

### 1.1 System diagram

```
                          ┌──────────────────────────┐
  Scanner .xlsx files ──► │  bulwark-scan-ingestor   │──┐ upsert vulnerabilities, assets,
  (data/vulnerabilities)  │  (batch / --watch job)   │  │ create/update incidents
                          └────────────┬─────────────┘  │
                                       │ incident.created / incident.updated
                                       │ scan.completed
                                       ▼                ▼
                          ┌──────────────────────┐   ┌───────────────────────────────┐
                          │ Kafka (Aiven / local │   │ PostgreSQL 16 + pgvector      │
                          │ Redpanda)            │   │  (single shared database)     │
                          │  bulwark.incidents   │   │                               │
                          │  bulwark.scans.      │   │  core tables   (bulwark-api)  │
                          │      completed       │   │  embeddings + recommender +   │
                          └──────────┬───────────┘   │  AI planner tables            │
                                     │  ▲            └───▲───────────▲──────────▲────┘
                    consume          │  │ incident.created│           │          │
                                     ▼  │ (incidents made │           │          │
                 ┌───────────────────────────┐  in the UI)│           │          │
                 │ solution-recommender      │────────────┘           │          │
                 │  engine 1: vector-        │ writes similar matches │          │
                 │    similarity (pgvector)  │ + AI plans + drafts    │          │
                 │  engine 2: ai-planner     │                        │          │
                 │    (Gemini Flash)         │◄── Gemini API (embeddings + LLM)  │
                 └───────────────────────────┘                        │          │
                                                                      │          │
   ┌──────────────┐  HTTPS/JSON + JWT  ┌──────────────────────────┐   │          │
   │  bulwark-ui  │ ─────────────────► │  bulwark-api (FastAPI)   │───┘          │
   │  React/Vite  │   /api/v1/*        │  :8000                   │              │
   │  :3000       │                    └──────────────────────────┘              │
   └──────────────┘                    ┌──────────────────────────┐              │
                                       │  execution worker        │──────────────┘
                                       │  (polls job_runs queue,  │  FOR UPDATE SKIP LOCKED
                                       │   simulated or real      │
                                       │   Ansible/SSM executors) │
                                       └──────────────────────────┘
```

### 1.2 How the parts talk to each other

* **The database is the integration point.** Every project reads and writes the same PostgreSQL database. `bulwark-api/sql/schema.sql` defines the core schema. The recommender adds its own tables (`sql/10_recommender.sql`, `sql/11_ai_planner.sql`) and the `incidents.embedding` vector column (`sql/02_pgvector_incidents.sql`).
* **Kafka carries events, not commands.** The scan ingestor and the API publish `incident.created` / `incident.updated` to `bulwark.incidents`. The message key is the incident id, so all events for one incident stay in order. The recommender consumes them. Delivery is at-least-once everywhere, and consumers de-duplicate on `event_id`.
* **The UI talks only to the API**, using a JWT bearer token. The API reads the AI planner's tables directly (`GET /incidents/{id}/ai-plan`) and lets a planner apply a suggested plan.
* **The execution worker is a separate process** from the same codebase as the API. It takes queued `job_runs` from the database and runs them.

### 1.3 End-to-end lifecycle

1. **Ingest:** a scan workbook dropped into `bulwark-scan-ingestor/data/vulnerabilities` becomes `vulnerabilities`, `assets` and one `OPEN` incident per vulnerability. An event is then published to Kafka. Analysts can also create incidents by hand in the UI.
2. **Recommend:** the recommender embeds the incident (Gemini, 768 dims), finds similar past incidents that have approved plans, and (with `ai-planner` on) asks Gemini Flash for an ordered plan built from **approved** catalog solutions. Where nothing in the catalog fits, it also writes drafts of new solutions.
3. **Plan:** an analyst builds the plan in the UI. Each step is pinned to an approved solution version. The analyst can write it by hand, copy it from another incident, or apply the AI suggestion.
4. **Approve:** the analyst submits the plan and an approver approves or rejects it. Solutions also go through their own review before they can be used in plans.
5. **Execute:** an operator runs the steps per asset. The worker runs each job (simulated by default). Step N runs on an asset only after step N‑1 succeeded on it.
6. **Resolve:** the incident resolves automatically once every non-excluded asset is patched.

Incident status flow: `OPEN → PENDING_APPROVAL → APPROVED → IN_PROGRESS → RESOLVED` (`REJECTED` returns to editing; `CLOSED` ends it).

### 1.4 Shared infrastructure

| Component | Used by | Notes |
|---|---|---|
| PostgreSQL 16 | all | Needs the **pgvector** extension for the recommender and embeddings. Local Docker: use the `pgvector/pgvector:pg16` image, because plain `postgres:16` has no pgvector. |
| Kafka | ingestor, API (optional), recommender | Aiven Kafka (SASL_SSL + SCRAM, CA cert at `certs/ca.pem` in each project) or local Redpanda from `bulwark-scan-ingestor/docker-compose.yml`. The API skips publishing when `KAFKA_BOOTSTRAP_SERVERS` is empty. |
| Google Gemini API | ingestor (`embed_incidents.py`), recommender | `gemini-embedding-001` (768 dims) for embeddings, `gemini-2.5-flash` for the AI planner. Free key: https://aistudio.google.com/apikey |

---

## 2. Prerequisites

* **Python 3.11+** (a shared virtual env already exists at `C:\SystemPatcher\.venv`, Python 3.13)
* **Node.js 18+** and npm (for the UI)
* **PostgreSQL 16 with pgvector**, either through Docker or a hosted database (e.g. Supabase, which has pgvector)
* **Kafka**: an Aiven cluster with credentials and `ca.pem`, or Docker for local Redpanda
* **psql** client (for applying SQL scripts)
* A **Gemini API key** (only for embeddings / recommender)

---

## 3. Setup and run (local, Windows PowerShell)

The commands below are for PowerShell. On bash, use `cp` instead of `Copy-Item` and `export VAR=...` instead of `$env:VAR = ...`.

### Step 0: Python environment

```powershell
cd C:\SystemPatcher
.\.venv\Scripts\Activate.ps1          # or: python -m venv .venv; then activate
pip install -e ".\bulwark-api[dev]"
pip install -e ".\bulwark-scan-ingestor[dev]"
pip install -e ".\bulwark-inc-planner-solution-recommender[dev]"
```

### Step 1: Database

Option A, local Docker with pgvector:

```powershell
docker run -d --name bulwark-db -p 5432:5432 `
  -e POSTGRES_USER=bulwark -e POSTGRES_PASSWORD=bulwark -e POSTGRES_DB=bulwark `
  pgvector/pgvector:pg16
```

Option B, use an existing / hosted PostgreSQL and put its URL in each project's `.env`.

### Step 2: bulwark-api (create schema, start API and worker)

```powershell
cd C:\SystemPatcher\bulwark-api
Copy-Item .env.example .env          # set DATABASE_URL, JWT_SECRET, CORS_ORIGINS, Kafka (or leave KAFKA_BOOTSTRAP_SERVERS empty)
alembic upgrade head                 # applies sql/schema.sql + migrations 0002-0004
```

`DATABASE_URL` for the API uses the async driver: `postgresql+asyncpg://bulwark:bulwark@localhost:5432/bulwark`.

Load data (pick **one**):

```powershell
python scripts\seed.py                                                     # tiny: demo assets + one vulnerability
# or the full demo set (52 users, 60 CVEs, 56 incidents, job history ...):
psql "postgresql://bulwark:bulwark@localhost:5432/bulwark" -f sql\02_sample_data.sql
psql "postgresql://bulwark:bulwark@localhost:5432/bulwark" -f sql\03_verify.sql
```

Run it as **two processes**:

```powershell
# terminal 1: API  -> http://localhost:8000/docs (Swagger)
uvicorn bulwark.main:app --app-dir src --reload

# terminal 2: execution worker (without it, runs stay "Queued")
$env:PYTHONPATH = "src"; python -m bulwark.modules.execution.worker
```

Get a login token:

```powershell
python scripts\dev_token.py ravi ANALYST OPERATOR      # paste into Swagger "Authorize" or the UI login page
python scripts\dev_token.py aarav.iyer ADMIN           # a seeded admin, when the sample data set is loaded
```

Alternative: `docker compose up` in `bulwark-api/` starts db + migrate + api + worker. Its `db` service uses plain `postgres:16`, so switch the image to `pgvector/pgvector:pg16` if you will run the recommender.

### Step 3: bulwark-ui

```powershell
cd C:\SystemPatcher\bulwark-ui
npm install
npm run dev                          # http://localhost:3000
```

The API URL defaults to `http://localhost:8000`. Change it with the gear icon in the header, in `public/config.js`, or with `VITE_API_BASE_URL`. The API's `CORS_ORIGINS` must include `http://localhost:3000`.

### Step 4: bulwark-scan-ingestor (optional: import scanner output)

```powershell
cd C:\SystemPatcher\bulwark-scan-ingestor
Copy-Item .env.example .env          # every key is required; set DATABASE_URL, Kafka, GEMINI_API_KEY
# put the Aiven CA certificate at certs\ca.pem
scan-ingestor --validate-only        # parse files only, touch nothing
scan-ingestor --kafka-dry-run        # write to DB, Kafka messages go to reports/kafka_dry_run.jsonl
scan-ingestor                        # real run over .\data\vulnerabilities
scan-ingestor --watch --interval 60  # keep polling the folder
```

Sample workbooks are in `samples/` (generate more with `scripts/make_sample_scan.py`). Copy one into `data/vulnerabilities/` to ingest it. The ingestor moves processed files to `processed/`, rejected files to `failed/`, and writes JSON reports to `reports/`.

To run fully locally without Aiven, start Postgres + Redpanda with `docker compose up -d`, then run `docker compose --profile job run ingestor`.

### Step 5: bulwark-inc-planner-solution-recommender (optional: AI suggestions)

```powershell
cd C:\SystemPatcher\bulwark-inc-planner-solution-recommender
Copy-Item .env.example .env          # DATABASE_URL, Kafka, GEMINI_API_KEY, ENGINES, MIN_SIMILARITY ...
psql $env:DATABASE_URL -f sql\02_pgvector_incidents.sql   # pgvector + incidents.embedding (once)
psql $env:DATABASE_URL -f sql\10_recommender.sql          # similarity tables/views
psql $env:DATABASE_URL -f sql\11_ai_planner.sql           # AI planner tables
python -m recommender --backfill-embeddings               # embed existing incidents once
python -m recommender                                     # consume bulwark.incidents until Ctrl+C
```

Useful modes:

```powershell
python -m recommender --incident 57              # run both engines for INC-57 now, no Kafka
python -m recommender --once                     # exit after 15 s idle (for cron / scheduled runs)
python -m recommender --from-file events.jsonl   # replay the ingestor's --kafka-dry-run output
python scripts\seed_demo_solutions.py            # DEMO DBs only: give some incidents an approved plan
```

### Recommended start order

1. Database → 2. `alembic upgrade head` + data → 3. API + worker → 4. UI → 5. recommender SQL + `--backfill-embeddings` → 6. recommender consumer → 7. scan ingestor whenever a new scan arrives.

---

## 4. Projects in detail

### 4.1 bulwark-api: the core backend

**Purpose:** the system of record. It holds the vulnerability → incident → solution → approval → execution workflow, enforces the business rules in both code and database constraints, and writes an append-only audit log.

**Code layout** (one folder per module, each with `router.py`, `service.py`, `models.py`, `schemas.py`):

```
src/bulwark/
  main.py              app factory; all routers under /api/v1
  core/                config, async DB session, JWT security + roles, errors, pagination, audit, Kafka publisher
  shared/              User, Asset, AuditLog models + common schemas
  modules/
    dashboard/         summary + "needs attention" widgets
    incident/          incidents, assets per incident, ordered plan, submit/close, AI-plan apply/dismiss
    approvals/         incident approvals + solution reviews (separate tabs)
    vulnerabilities/   CRUD + activate/deactivate
    solution/          versioned solution catalog, retire, suggestions (suggest.py, keyword baseline)
    execution/         run steps, grid per incident, logs, cancel; worker.py; executors/ (simulated | real)
    assets/            inventory, facets, pickers
    reference/         GET /users (assignee dropdown)
sql/schema.sql         single source of truth for the DB (Alembic revision 0001 applies it)
migrations/            Alembic (async); 0002-0004 relax self-approval checks, add job_run chain
scripts/               dev_token.py, seed.py, generate_sample_data.py
tests/test_flow.py     end-to-end flow against a real PostgreSQL
```

**Roles:** `ANALYST` (create/edit vulnerabilities, incidents, solutions), `OPERATOR` (run jobs), `APPROVER` (decide approvals), `ADMIN` (everything), `VIEWER` (read-only).

**Key rules:**
* One open incident per vulnerability (partial unique index). Inactive vulnerabilities cannot get incidents.
* Every solution version starts `REVIEW_PENDING`. Only `APPROVED` versions can be used in plans.
* The plan and asset list lock once the incident is submitted.
* Execution only for `APPROVED` / `IN_PROGRESS` incidents. Steps run in order per asset, re-running is idempotent, and failed runs can be retried.
* **Worker:** a database-backed queue (`FOR UPDATE SKIP LOCKED`) with timeouts, stale-run recovery and auto-retry. `SIMULATE_EXECUTORS=true` (the default) simulates jobs. Real Ansible / AWS SSM execution is a stub in `executors/real.py`.
* **Kafka:** publishes `incident.created` when an incident is created through the API. Publishing is skipped if Kafka isn't configured.

**Tests:** `$env:TEST_DATABASE_URL="postgresql+asyncpg://..."; pytest -q`. The target schema is dropped and recreated.

### 4.2 bulwark-ui: the web front end

**Purpose:** the browser UI for the whole workflow.

```
src/
  main.jsx, App.jsx    routing
  config.js            API base URL resolution (settings → public/config.js → VITE_API_BASE_URL → default)
  api/                 client.js (fetch + JWT), endpoints.js (one function per API call)
  auth/                AuthContext, LoginPage (paste token, or dev-only in-browser token from JWT_SECRET)
  components/          Layout (sidebar), shared UI widgets
  pages/               Dashboard, Incidents, IncidentForm, IncidentView (incl. "AI Suggested" tab),
                       Approvals, Vulnerabilities, Solutions, Assets, Execution
```

* Role checks in the UI only enable or disable buttons. The API is what enforces them.
* `npm run build` writes static files to `dist/`. `public/config.js` is copied as-is, so you can change the API URL after building.
* Tests (with the API and worker running): `$env:JWT_SECRET="<secret>"; npm run smoke` runs the full flow, and `npm test` renders each page against the live API.

### 4.3 bulwark-scan-ingestor: the scan import job

**Purpose:** turns scanner output into Bulwark data, with no manual entry.

**Workbook format** (`samples/`): a `Scan` sheet (key/value metadata), a `Vulnerabilities` sheet (cve_id, title, severity, cvss_score, affected_assets `;`-separated, ...), and an optional `Assets` sheet. A file is rejected if more than 20 % of its rows are invalid or a required sheet/column is missing.

```
src/scan_ingestor/
  cli.py / run.py      entry points (scan-ingestor command, or python src/scan_ingestor/run.py)
  reader.py            parse + validate xlsx (openpyxl)
  schemas.py           pydantic row models
  pipeline.py          per-file orchestration
  service.py           incident rules (create / reopen / update / skip)
  repository.py        SQL (psycopg 3)
  publisher.py         Kafka producer (idempotent, acks=all) + dry-run/in-memory publishers
  messages.py          event payloads (docs/kafka/*.schema.json + examples/)
  embed_incidents.py   standalone: fill incidents.embedding via Gemini
```

**Behaviour:**
* Upserts vulnerabilities and assets. For existing vulnerabilities it refreshes only CVSS/severity and only adds assets.
* Creates one incident per vulnerability, or reopens with a link to the previous incident, or updates assets/severity while the incident is still OPEN/REJECTED.
* The DB changes for one file commit in a single transaction, together with a SHA-256 marker. Kafka publishing comes after the commit. If Kafka fails, the next run re-sends the same events with the same `event_id`.
* A Postgres advisory lock lets only one instance run at a time.
* Exit codes: `0` ok · `1` a file was rejected or Kafka delivery failed · `2` config error or Kafka unreachable · `3` another instance is running.

**Tests:** `$env:TEST_DATABASE_URL="postgresql://..."; pytest -q`. This **drops the public schema** of that database.

### 4.4 bulwark-inc-planner-solution-recommender: similarity + AI planner

**Purpose:** reuses past knowledge. For every incident event it finds similar earlier incidents that have an approved plan, and can ask an LLM to put together a plan from the approved solution catalog.

```
src/recommender/
  __main__.py, cli.py  entry point and modes (--backfill-embeddings, --incident, --once, --from-file)
  sources.py           Kafka consumer / file source
  events.py            event parsing + validation (schema_version 1.x)
  processor.py         batching, retries, offset commits, dead letters
  embeddings.py        Gemini embeddings (768 dims) + rate limiting
  engines.py           Engine protocol + "vector-similarity" engine (pgvector cosine search)
  ai_planner.py        "ai-planner" engine (Gemini Flash, structured JSON, validated against the catalog)
  repo.py              SQL
sql/
  02_pgvector_incidents.sql   CREATE EXTENSION vector; incidents.embedding + HNSW index
  10_recommender.sql          incident_suggestion_runs, incident_similar_matches, dead letters, views
  11_ai_planner.sql           incident_ai_plans, incident_ai_plan_steps, ai_solution_drafts
```

**Engines** (set with `ENGINES=vector-similarity,ai-planner`, in that order):
* **vector-similarity:** finds the nearest incidents by cosine similarity. Candidates must have a plan, have an approved status (`CANDIDATE_STATUSES`), use the same embedding model, and score at least `MIN_SIMILARITY`. Results go to `incident_similar_matches` with a rank. The plan itself is not copied.
* **ai-planner:** sends Gemini Flash the incident, the approved catalog (`job_spec` is never sent) and the plans of the most similar incidents. Every step it returns must reference a real catalog entry. Invalid output gets one retry, after which the run is stored as `FAILED`. Identical input reuses the previous answer. The output is only a **suggestion**: a planner applies it in the UI, and it still goes through normal approval.

**Guarantees:** at-least-once delivery, with offsets committed after the batch is stored. A redelivered event is skipped through `UNIQUE (trigger_event_id, engine)`. Transient errors are retried with back-off. Bad messages go to `recommender_dead_letters`.

**Notes:** tune `MIN_SIMILARITY` against real similarity scores. A fresh database has no incidents with approved plans, so `NO_MATCH` is expected there. To add a new engine, implement the `Engine` protocol in `engines.py`.

**Tests:** `$env:TEST_DATABASE_URL="postgresql://..."; pytest -q` (needs pgvector, **drops the public schema**).

---

## 5. Configuration summary

Every project reads its settings from its own `.env` file (copy it from `.env.example`). Never commit `.env` files or `certs/ca.pem`.

| Setting | api | ingestor | recommender | Notes |
|---|:-:|:-:|:-:|---|
| `DATABASE_URL` | ✔ (`postgresql+asyncpg://`) | ✔ | ✔ | Same database for all |
| `JWT_SECRET`, `JWT_ALGORITHM` | ✔ | | | Also used by the UI dev login and smoke tests |
| `CORS_ORIGINS` | ✔ | | | Must include the UI origin |
| `SIMULATE_EXECUTORS`, `WORKER_POLL_SECONDS` | ✔ | | | Worker behaviour |
| `KAFKA_*` | optional | ✔ | ✔ | Same cluster; topic `bulwark.incidents` |
| `GEMINI_API_KEY`, `GEMINI_*`, `EMBED_*` | | ✔ (embeddings) | ✔ | Embedding model and dimension must match across projects |
| `ENGINES`, `TOP_K`, `MIN_SIMILARITY`, `PLAN_*` | | | ✔ | Recommender tuning |
| `INGEST_*` | | ✔ | | Folder, timezone, bot user, invalid-row threshold |

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Execution runs stay **Queued** | The worker isn't running. Start `python -m bulwark.modules.execution.worker` with `PYTHONPATH=src`. |
| UI shows network / CORS errors | Add the UI origin to `CORS_ORIGINS` in `bulwark-api/.env`, and check the API URL in the UI settings (gear icon). |
| API returns 500 after login with a new token | You minted a token with a random id for an email that already exists. Use the seeded user's slug with `dev_token.py`. |
| `type "vector" does not exist` | pgvector isn't installed. Use the `pgvector/pgvector:pg16` image or enable the extension on the hosted DB. |
| Recommender only produces `NO_MATCH` | No past incidents with approved plans yet. Load sample data or run `scripts/seed_demo_solutions.py`, then `--backfill-embeddings`. |
| Ingestor exits with code 2 | Bad config or Kafka unreachable. Check `KAFKA_*` and `certs/ca.pem`, or try `--kafka-dry-run`. |
| Ingestor exits with code 3 | Another ingestor instance holds the advisory lock. |

Each project's own `README.md` has more detail.
