# Bulwark: Local Setup and Run Guide

How to set up the Bulwark projects on a Windows machine and run them in **8 terminals**.
For the architecture and each project in detail, see [README.md](README.md).

## The 6 projects

| # | Project | Folder | Tech |
|---|---|---|---|
| 1 | Core API + execution worker | [bulwark-api](bulwark-api/) | Python, FastAPI, SQLAlchemy, Alembic |
| 2 | Solution recommender (similarity + AI planner) | [bulwark-inc-planner-solution-recommender](bulwark-inc-planner-solution-recommender/) | Python, pgvector, Gemini, Kafka consumer |
| 3 | AI assistant (MCP server + chat agent) | [bulwark-ai](bulwark-ai/) | Python, MCP, LangGraph, Gemini |
| 4 | Main web UI | [bulwark-ui](bulwark-ui/) | React 18, Vite |
| 5 | Assistant chat UI | [bulwark-agent-ui](bulwark-agent-ui/) | React 18, Vite |
| 6 | Scan ingestor | [bulwark-scan-ingestor](bulwark-scan-ingestor/) | Python, openpyxl, Kafka producer |

All Python projects share one virtual env: `C:\SystemPatcher\.venv`.
All projects share one PostgreSQL database (with pgvector) and one Kafka topic (`bulwark.incidents`).

## The 8 terminals at a glance

| Terminal | What it does | Folder | Command | Port / URL |
|---|---|---|---|---|
| 1 | **API**: REST backend, the system of record | `bulwark-api` | `uvicorn bulwark.main:app --app-dir src --reload` | http://localhost:8000/docs |
| 2 | **Execution worker**: runs queued patch jobs | `bulwark-api` | `$env:PYTHONPATH="src"; python -m bulwark.modules.execution.worker` | (no port) |
| 3 | **Recommender**: consumes incident events, finds similar incidents, drafts AI plans | `bulwark-inc-planner-solution-recommender` | `python -m recommender` | (no port) |
| 4 | **MCP server**: exposes Bulwark functions as 60 tools over the REST API | `bulwark-ai\bulwark-mcp-server` | `bulwark-mcp` | http://127.0.0.1:8765/mcp |
| 5 | **Chat server**: LangGraph agent, HTTP API for the chat widgets | `bulwark-ai\bulwark-chat-agent` | `bulwark-chat-server` | http://127.0.0.1:8800 |
| 6 | **Main UI**: screens for analysts, approvers, operators | `bulwark-ui` | `npm run dev` | http://localhost:3000 |
| 7 | **Agent UI**: standalone assistant chat app | `bulwark-agent-ui` | `npm run dev` | http://localhost:3100 |
| 8 | **Scan ingestor**: watches a folder for scanner `.xlsx` files and loads them | `bulwark-scan-ingestor` | `scan-ingestor --watch --interval 60` | (no port) |

Request flow:

```
bulwark-ui :3000 ─────────────────────────────────────────────► API :8000 ──► PostgreSQL
bulwark-ui / agent-ui :3100 ─► chat server :8800 ─► MCP :8765 ─►    │            ▲
                                                                    ▼            │
scan ingestor ──► Kafka (bulwark.incidents) ──► recommender ─────────────────────┘
                                                worker (polls job_runs) ─────────┘
```

---

## 1. Prerequisites

- Python 3.11+ (the existing `.venv` uses 3.13)
- Node.js 18+ and npm
- PostgreSQL 16 **with pgvector** (local Docker `pgvector/pgvector:pg16`, or a hosted DB such as Supabase)
- Kafka: an Aiven cluster with credentials and its `ca.pem`, or local Redpanda (`bulwark-scan-ingestor/docker-compose.yml`)
- `psql` client
- A Gemini API key: https://aistudio.google.com/apikey

## 2. One-time setup

All commands are PowerShell, starting from `C:\SystemPatcher`.

### 2.1 Python environment

```powershell
cd C:\SystemPatcher
python -m venv .venv                     # skip if .venv already exists
.\.venv\Scripts\Activate.ps1
pip install -e ".\bulwark-api[dev]"
pip install -e ".\bulwark-scan-ingestor[dev]"
pip install -e ".\bulwark-inc-planner-solution-recommender[dev]"
pip install -e ".\bulwark-ai\bulwark-mcp-server[dev]"
pip install -e ".\bulwark-ai\bulwark-chat-agent[dev]"
```

### 2.2 Database (skip if you use a hosted DB)

```powershell
docker run -d --name bulwark-db -p 5432:5432 `
  -e POSTGRES_USER=bulwark -e POSTGRES_PASSWORD=bulwark -e POSTGRES_DB=bulwark `
  pgvector/pgvector:pg16
```

### 2.3 Environment files

Copy each `.env.example` to `.env` and fill it in. Never commit `.env` files or `certs\ca.pem`.

```powershell
Copy-Item bulwark-api\.env.example                              bulwark-api\.env
Copy-Item bulwark-inc-planner-solution-recommender\.env.example bulwark-inc-planner-solution-recommender\.env
Copy-Item bulwark-ai\bulwark-mcp-server\.env.example            bulwark-ai\bulwark-mcp-server\.env
Copy-Item bulwark-ai\bulwark-chat-agent\.env.example            bulwark-ai\bulwark-chat-agent\.env
Copy-Item bulwark-scan-ingestor\.env.example                    bulwark-scan-ingestor\.env
```

| Project | Settings you must set |
|---|---|
| bulwark-api | `DATABASE_URL` (async form: `postgresql+asyncpg://bulwark:bulwark@localhost:5432/bulwark`), `JWT_SECRET`, `CORS_ORIGINS=["http://localhost:3000","http://localhost:3100"]`, `GEMINI_API_KEY`, `SCAN_INBOX` / `SCAN_INGESTOR_DIR` / `SCAN_INGESTOR_CMD`. Kafka is optional: leave `KAFKA_BOOTSTRAP_SERVERS` empty to disable it. |
| recommender | `DATABASE_URL`, `KAFKA_*`, `GEMINI_API_KEY`, `ENGINES`, `MIN_SIMILARITY` |
| mcp-server | `BULWARK_API_URL=http://localhost:8000` |
| chat-agent | `GEMINI_API_KEY`, `BULWARK_JWT_SECRET` (same value as the API's `JWT_SECRET`), `MCP_URL`, `CORS_ORIGINS`, `CHAT_DATABASE_URL` (empty keeps chat history in memory only) |
| scan-ingestor | Every key is required: `DATABASE_URL`, `INGEST_*`, `KAFKA_*`, `GEMINI_API_KEY` |
| bulwark-ui / agent-ui | No `.env` needed. The defaults point at `localhost:8000` / `localhost:8800`; change them with the gear icon or `public/config.js`. |

For Aiven Kafka, put the CA certificate at `certs\ca.pem` in each project that uses Kafka (api, recommender, scan-ingestor).

### 2.4 Database schema and data

```powershell
# Core schema (bulwark-api owns it)
cd C:\SystemPatcher\bulwark-api
alembic upgrade head

# Sample data: pick ONE
python scripts\seed.py                                                  # tiny demo
psql "postgresql://bulwark:bulwark@localhost:5432/bulwark" -f sql\02_sample_data.sql   # full demo set
psql "postgresql://bulwark:bulwark@localhost:5432/bulwark" -f sql\03_verify.sql

# Recommender tables + embeddings (once)
cd C:\SystemPatcher\bulwark-inc-planner-solution-recommender
psql "<DATABASE_URL>" -f sql\02_pgvector_incidents.sql
psql "<DATABASE_URL>" -f sql\10_recommender.sql
psql "<DATABASE_URL>" -f sql\11_ai_planner.sql
python -m recommender --backfill-embeddings

# Chat history tables (once; only if CHAT_DATABASE_URL is set)
cd C:\SystemPatcher\bulwark-ai\bulwark-chat-agent
psql "<CHAT_DATABASE_URL>" -f sql\01_chat_history.sql
```

### 2.5 Node packages

```powershell
cd C:\SystemPatcher\bulwark-ui;       npm install
cd C:\SystemPatcher\bulwark-agent-ui; npm install
```

---

## 3. Start the 8 terminals

In every **Python** terminal, activate the venv first:

```powershell
C:\SystemPatcher\.venv\Scripts\Activate.ps1
```

Start them in this order. Each later service depends on the ones before it.

### Terminal 1: API

```powershell
cd C:\SystemPatcher\bulwark-api
uvicorn bulwark.main:app --app-dir src --reload
```

Check: http://localhost:8000/docs opens Swagger.

### Terminal 2: Execution worker

```powershell
cd C:\SystemPatcher\bulwark-api
$env:PYTHONPATH = "src"; python -m bulwark.modules.execution.worker
```

Without it, execution runs stay **Queued**. Jobs are simulated while `SIMULATE_EXECUTORS=true`.

### Terminal 3: Recommender

```powershell
cd C:\SystemPatcher\bulwark-inc-planner-solution-recommender
python -m recommender
```

Consumes `bulwark.incidents` until Ctrl+C. To test one incident without Kafka: `python -m recommender --incident 57`.

### Terminal 4: MCP server

```powershell
cd C:\SystemPatcher\bulwark-ai\bulwark-mcp-server
bulwark-mcp
```

Check: http://127.0.0.1:8765/health

### Terminal 5: Chat server

```powershell
cd C:\SystemPatcher\bulwark-ai\bulwark-chat-agent
bulwark-chat-server
```

Listens on http://127.0.0.1:8800. Needs terminals 1 and 4. For a terminal chat instead: `bulwark-chat --user ravi --roles ANALYST,OPERATOR`.

### Terminal 6: Main UI

```powershell
cd C:\SystemPatcher\bulwark-ui
npm run dev
```

Open http://localhost:3000. It also shows a floating chat icon that uses terminal 5.

### Terminal 7: Agent UI

```powershell
cd C:\SystemPatcher\bulwark-agent-ui
npm run dev
```

Open http://localhost:3100.

### Terminal 8: Scan ingestor

```powershell
cd C:\SystemPatcher\bulwark-scan-ingestor
scan-ingestor --watch --interval 60
```

Drop a scanner workbook (samples are in `samples\`) into `data\vulnerabilities\`. Processed files move to `processed\`, rejected ones to `failed\`, and reports go to `reports\`.
For a one-off run, use `scan-ingestor` without `--watch`. To test without touching anything, use `scan-ingestor --validate-only` or `--kafka-dry-run`.

---

## 4. Signing in

Both UIs need a Bulwark JWT. Create one from `bulwark-api`:

```powershell
cd C:\SystemPatcher\bulwark-api
python scripts\dev_token.py ravi ANALYST OPERATOR
python scripts\dev_token.py aarav.iyer ADMIN        # seeded admin, when the full sample data is loaded
```

Paste the token on the UI login page or in Swagger's **Authorize** dialog.

## 5. Quick health check

| Check | Expected |
|---|---|
| http://localhost:8000/docs | Swagger page |
| http://127.0.0.1:8765/health | OK |
| http://localhost:3000 | Bulwark login |
| http://localhost:3100 | Assistant login |
| Run an execution step in the UI | Moves from Queued to Succeeded (worker is running) |

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| Execution runs stay **Queued** | Terminal 2 (worker) is not running, or `PYTHONPATH=src` was not set. |
| UI shows network / CORS errors | Add the UI origin to `CORS_ORIGINS` in `bulwark-api\.env` (and in the chat agent's `.env` for the assistant). |
| Chat says it cannot reach tools | Start terminal 4 before terminal 5; check `MCP_URL`. |
| Chat returns 401 | `BULWARK_JWT_SECRET` in the chat agent differs from the API's `JWT_SECRET`. |
| `type "vector" does not exist` | pgvector is missing. Use the `pgvector/pgvector:pg16` image or enable the extension. |
| Recommender only shows `NO_MATCH` | No past incidents with approved plans. Load the sample data or run `python scripts\seed_demo_solutions.py`, then `--backfill-embeddings`. |
| Ingestor exits with code 2 | Bad config or Kafka unreachable: check `KAFKA_*` and `certs\ca.pem`, or try `--kafka-dry-run`. |
| Ingestor exits with code 3 | Another ingestor instance is already running. |
| Port already in use | Another copy is still running. Stop it, or for a Vite UI run `npx vite --port <other>`. |
