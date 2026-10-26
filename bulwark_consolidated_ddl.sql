-- ====================================================================================================
-- BULWARK - CONSOLIDATED DDL  (PostgreSQL 14+ ; tested on PostgreSQL 16 + pgvector 0.6)
--
-- One script that creates the complete Bulwark database for ALL six projects:
--   PART 1  Core schema            bulwark-api, bulwark-scan-ingestor           (15 tables)
--   PART 2  Vector search columns  bulwark-scan-ingestor, recommender, API     (incidents.embedding + indexes)
--   PART 3  Recommender tables     bulwark-inc-planner-solution-recommender    (3 tables + 1 view)
--   PART 4  AI planner tables      bulwark-inc-planner-solution-recommender    (3 tables)
--   PART 5  Chat history schema    bulwark-ai/bulwark-chat-agent (schema bulwark_chat, 5 tables)
--
-- Use on an EMPTY database. Needs: CREATE EXTENSION privilege for pgvector (extension name: vector).
-- Run:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f bulwark_consolidated_ddl.sql
-- Then (optional demo data):  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f bulwark_consolidated_inserts.sql
--
-- This is the FINAL state of the schema: it already contains the changes that the incremental scripts apply
-- (sql/04 and sql/06 self-approval CHECKs removed, sql/05 job_runs.chain, sql/07 username/password + refresh_tokens).
-- If your database is managed by Alembic (bulwark-api), do NOT run PART 1; run `alembic upgrade head` instead and
-- use parts 2-5 only.
--
-- To start over on a dev/test database, uncomment and run the reset block below FIRST (destroys all data):
--   DROP SCHEMA IF EXISTS bulwark_chat CASCADE;
--   DROP VIEW  IF EXISTS v_incident_similar_matches;
--   DROP TABLE IF EXISTS ai_solution_drafts, incident_ai_plan_steps, incident_ai_plans, incident_similar_matches,
--        incident_suggestion_runs, recommender_dead_letters, job_run_logs, job_runs, incident_approvals,
--        incident_plan_steps, incident_assets, incidents, solution_reviews, solution_versions, solutions,
--        vulnerability_assets, vulnerabilities, assets, audit_logs, refresh_tokens, users CASCADE;
-- ====================================================================================================

-- ====================================================================================================
-- PART 1: CORE SCHEMA (15 tables)
-- Source: bulwark-api/sql/schema.sql (final state)
-- ====================================================================================================
CREATE TABLE users (
  id          UUID PRIMARY KEY,
  email       TEXT NOT NULL,
  full_name   TEXT NOT NULL,
  roles       TEXT[] NOT NULL DEFAULT '{}',
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  username             TEXT,                               -- sign-in name (scripts/init_auth.py fills it from email)
  password_hash        TEXT,                               -- scrypt hash, never the password
  must_change_password BOOLEAN NOT NULL DEFAULT TRUE,
  failed_logins        INT NOT NULL DEFAULT 0,
  locked_until         TIMESTAMPTZ,
  last_login_at        TIMESTAMPTZ,
  password_changed_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX ux_users_email ON users (lower(email));
CREATE UNIQUE INDEX ux_users_username ON users (lower(username));

-- Refresh tokens (only their SHA-256). A login starts a family; each refresh rotates within it.
CREATE TABLE refresh_tokens (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id          UUID NOT NULL,
  token_hash         TEXT NOT NULL UNIQUE,
  session_started_at TIMESTAMPTZ NOT NULL,
  expires_at         TIMESTAMPTZ NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at         TIMESTAMPTZ,
  revoked_reason     TEXT,
  replaced_by        UUID,
  user_agent         TEXT,
  ip                 TEXT
);
CREATE INDEX ix_refresh_tokens_user ON refresh_tokens (user_id);
CREATE INDEX ix_refresh_tokens_family ON refresh_tokens (family_id);

CREATE TABLE assets (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name         TEXT NOT NULL UNIQUE,
  asset_type   TEXT NOT NULL CHECK (asset_type IN ('SYSTEM','APPLICATION')),
  environment  TEXT NOT NULL,
  hostname     TEXT,
  os_name      TEXT,
  os_version   TEXT,
  owner_team   TEXT,
  attributes   JSONB NOT NULL DEFAULT '{}',
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_assets_env ON assets (environment);

-- ---------------------------------------------------------------- vulnerabilities
CREATE TABLE vulnerabilities (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cve_id       TEXT NOT NULL UNIQUE,
  title        TEXT NOT NULL,
  description  TEXT,                                   -- NEW: free-text description
  severity     TEXT NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  cvss_score   NUMERIC(3,1) CHECK (cvss_score BETWEEN 0 AND 10),
  source       TEXT NOT NULL DEFAULT 'MANUAL',
  published_at TIMESTAMPTZ,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,          -- activate / deactivate
  created_by   UUID REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_vuln_severity ON vulnerabilities (severity);
CREATE INDEX ix_vuln_active ON vulnerabilities (is_active);

CREATE TABLE vulnerability_assets (
  vulnerability_id UUID NOT NULL REFERENCES vulnerabilities(id) ON DELETE CASCADE,
  asset_id         UUID NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  PRIMARY KEY (vulnerability_id, asset_id)
);

-- ---------------------------------------------------------------- solutions
CREATE TABLE solutions (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title              TEXT NOT NULL,
  description        TEXT,
  is_retired         BOOLEAN NOT NULL DEFAULT FALSE,
  current_version_id UUID,                              -- latest version (any status)
  created_by         UUID REFERENCES users(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Immutable content of a solution. Approval applies to a version, never to "the solution".
CREATE TABLE solution_versions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solution_id      UUID NOT NULL REFERENCES solutions(id) ON DELETE CASCADE,
  version_no       INT  NOT NULL,
  title            TEXT NOT NULL,
  description      TEXT,
  executor         TEXT NOT NULL CHECK (executor IN ('ANSIBLE','AWS_SSM','SHELL','HTTP')),
  job_spec         JSONB NOT NULL DEFAULT '{}',        -- playbook path, SSM document, command...
  applies_to       TEXT,
  risk_level       TEXT NOT NULL DEFAULT 'MEDIUM' CHECK (risk_level IN ('LOW','MEDIUM','HIGH')),
  requires_reboot  BOOLEAN NOT NULL DEFAULT FALSE,
  timeout_seconds  INT NOT NULL DEFAULT 1800 CHECK (timeout_seconds > 0),
  max_retries      SMALLINT NOT NULL DEFAULT 0 CHECK (max_retries BETWEEN 0 AND 5),
  status           TEXT NOT NULL DEFAULT 'REVIEW_PENDING'
                   CHECK (status IN ('REVIEW_PENDING','APPROVED','REJECTED','CHANGES_REQUESTED')),
  created_by       UUID REFERENCES users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (solution_id, version_no)
);
ALTER TABLE solutions
  ADD CONSTRAINT fk_solutions_current_version
  FOREIGN KEY (current_version_id) REFERENCES solution_versions(id);

-- Level-1 review of a solution version (Approvals -> Solution approvals tab)
CREATE TABLE solution_reviews (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  solution_version_id UUID NOT NULL REFERENCES solution_versions(id) ON DELETE CASCADE,
  level               SMALLINT NOT NULL DEFAULT 1,
  status              TEXT NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','APPROVED','REJECTED','CHANGES_REQUESTED')),
  requested_by        UUID NOT NULL REFERENCES users(id),
  reviewer_id         UUID REFERENCES users(id),
  comment             TEXT,
  requested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at          TIMESTAMPTZ
  -- no self-review CHECK: approvers may decide their own solution submissions (sql/04_allow_solution_self_review.sql)
);
CREATE UNIQUE INDEX ux_solution_review_pending
  ON solution_reviews (solution_version_id, level) WHERE status = 'PENDING';

-- ---------------------------------------------------------------- incidents
CREATE TABLE incidents (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_no    BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,         -- shown as INC-<no>
  vulnerability_id UUID NOT NULL REFERENCES vulnerabilities(id),     -- one incident per vulnerability
  title          TEXT NOT NULL,
  description    TEXT,                                                -- NEW: free-text description
  severity       TEXT NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  status         TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN
                 ('OPEN','PENDING_APPROVAL','APPROVED','REJECTED','IN_PROGRESS','RESOLVED','CLOSED')),
  assignee_id    UUID REFERENCES users(id),
  created_by     UUID REFERENCES users(id),
  submitted_by   UUID REFERENCES users(id),
  submitted_at   TIMESTAMPTZ,
  closed_at      TIMESTAMPTZ,
  resolved_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_incidents_status ON incidents (status);
CREATE INDEX ix_incidents_vuln ON incidents (vulnerability_id);
-- Only one non-finished incident per vulnerability
CREATE UNIQUE INDEX ux_incident_open_per_vuln
  ON incidents (vulnerability_id) WHERE status NOT IN ('RESOLVED','CLOSED');

-- Impacted assets of an incident
CREATE TABLE incident_assets (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id  UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  asset_id     UUID NOT NULL REFERENCES assets(id),
  status       TEXT NOT NULL DEFAULT 'PENDING'
               CHECK (status IN ('PENDING','IN_PROGRESS','PATCHED','FAILED','EXCLUDED')),
  exclude_reason TEXT,
  last_error   TEXT,
  patched_at   TIMESTAMPTZ,
  UNIQUE (incident_id, asset_id)
);

-- Ordered solutions to apply for the incident (each pinned to an approved version)
CREATE TABLE incident_plan_steps (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id         UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  step_no             SMALLINT NOT NULL CHECK (step_no > 0),
  solution_version_id UUID NOT NULL REFERENCES solution_versions(id),
  on_failure          TEXT NOT NULL DEFAULT 'STOP_ASSET' CHECK (on_failure IN ('STOP_ASSET','CONTINUE','STOP_ALL')),
  UNIQUE (incident_id, step_no),
  UNIQUE (incident_id, solution_version_id)
);

-- Level-1 approval of an incident plan (Approvals -> Incident approvals tab)
CREATE TABLE incident_approvals (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id   UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  level         SMALLINT NOT NULL DEFAULT 1,
  status        TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
  requested_by  UUID NOT NULL REFERENCES users(id),
  decided_by    UUID REFERENCES users(id),
  comment       TEXT,
  plan_snapshot JSONB NOT NULL DEFAULT '[]',          -- plan as submitted, for audit
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at    TIMESTAMPTZ
  -- no self-approval CHECK: approvers may decide their own submissions (sql/06_allow_incident_self_approval.sql)
);
CREATE UNIQUE INDEX ux_incident_approval_pending
  ON incident_approvals (incident_id, level) WHERE status = 'PENDING';

-- ---------------------------------------------------------------- execution
CREATE TABLE job_runs (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id      UUID NOT NULL REFERENCES incidents(id),
  plan_step_id     UUID NOT NULL REFERENCES incident_plan_steps(id),
  incident_asset_id UUID NOT NULL REFERENCES incident_assets(id),
  attempt          SMALLINT NOT NULL DEFAULT 1,
  status           TEXT NOT NULL DEFAULT 'QUEUED'
                   CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED')),
  idempotency_key  TEXT NOT NULL UNIQUE,
  exit_code        INT,
  result           JSONB,
  error_message    TEXT,
  triggered_by     UUID REFERENCES users(id),
  chain            BOOLEAN NOT NULL DEFAULT FALSE,     -- "Run" (whole plan): worker queues the asset's next step after it
  locked_by        TEXT,
  queued_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at       TIMESTAMPTZ,
  finished_at      TIMESTAMPTZ
);
CREATE INDEX ix_job_runs_queue ON job_runs (status, queued_at);
CREATE INDEX ix_job_runs_incident ON job_runs (incident_id);
-- never two live runs for the same step + asset ...
CREATE UNIQUE INDEX ux_job_runs_active
  ON job_runs (plan_step_id, incident_asset_id) WHERE status IN ('QUEUED','RUNNING');
-- ... and a succeeded step is never run again
CREATE UNIQUE INDEX ux_job_runs_succeeded
  ON job_runs (plan_step_id, incident_asset_id) WHERE status = 'SUCCEEDED';

CREATE TABLE job_run_logs (
  id         BIGSERIAL PRIMARY KEY,
  job_run_id UUID NOT NULL REFERENCES job_runs(id) ON DELETE CASCADE,
  stream     TEXT NOT NULL DEFAULT 'stdout',
  message    TEXT NOT NULL,
  logged_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_job_run_logs_run ON job_run_logs (job_run_id, id);

-- ---------------------------------------------------------------- audit
CREATE TABLE audit_logs (
  id          BIGSERIAL PRIMARY KEY,
  actor_id    UUID REFERENCES users(id),
  action      TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   TEXT NOT NULL,
  before      JSONB,
  after       JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_entity ON audit_logs (entity_type, entity_id);

-- ====================================================================================================
-- PART 2: VECTOR SEARCH ON INCIDENTS (pgvector)
-- Source: recommender sql/02_pgvector_incidents.sql
-- Dimension 768 = Gemini gemini-embedding-001 (output_dimensionality=768). Embeddings are filled by the scan-ingestor / recommender
-- (`--backfill-embeddings`); the sample data leaves them NULL.
-- ====================================================================================================
CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE incidents
  ADD COLUMN IF NOT EXISTS embedding           vector(768),
  ADD COLUMN IF NOT EXISTS embedding_model     TEXT,          -- e.g. gemini:gemini-embedding-001:768 - only compare vectors with the same value
  ADD COLUMN IF NOT EXISTS embedding_text_hash TEXT,          -- sha256 of the text that was embedded; re-embed when it changes
  ADD COLUMN IF NOT EXISTS embedded_at         TIMESTAMPTZ;

-- Cosine distance, approximate nearest neighbour. Partial: rows without a vector are not indexed.
CREATE INDEX IF NOT EXISTS ix_incidents_embedding_hnsw
  ON incidents USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;

-- Rows still to embed (used by incident-embed)
CREATE INDEX IF NOT EXISTS ix_incidents_not_embedded ON incidents (created_at) WHERE embedding IS NULL;

-- ====================================================================================================
-- PART 3: RECOMMENDER RESULT TABLES
-- Source: recommender sql/10_recommender.sql
-- ====================================================================================================
CREATE TABLE IF NOT EXISTS incident_suggestion_runs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id       UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  trigger_event_id  TEXT NOT NULL,                       -- event_id of the Kafka message; redelivery cannot create a second run
  trigger_event_type TEXT NOT NULL,                      -- incident.created | incident.updated
  scan_id           TEXT,
  kafka_topic       TEXT,
  kafka_partition   INT,
  kafka_offset      BIGINT,
  engine            TEXT NOT NULL,                       -- 'vector-similarity' today
  embedding_model   TEXT,                                -- model that produced the vectors compared in this run
  params            JSONB NOT NULL DEFAULT '{}',         -- top_k, min_similarity, candidate statuses ...
  status            TEXT NOT NULL CHECK (status IN ('COMPLETED','NO_MATCH','SUPERSEDED','FAILED')),   -- FAILED: ai-planner (11_ai_planner.sql)
  similar_found     INT NOT NULL DEFAULT 0,
  is_current        BOOLEAN NOT NULL DEFAULT FALSE,      -- the latest usable run of this engine for the incident
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (trigger_event_id, engine)
);
CREATE INDEX IF NOT EXISTS ix_suggestion_runs_incident ON incident_suggestion_runs (incident_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS ux_suggestion_run_current ON incident_suggestion_runs (incident_id, engine) WHERE is_current;

CREATE TABLE IF NOT EXISTS incident_similar_matches (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id              UUID NOT NULL REFERENCES incident_suggestion_runs(id) ON DELETE CASCADE,
  incident_id         UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,        -- the incident from the Kafka event
  similar_incident_id UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,        -- an earlier incident that has a plan (incident_plan_steps)
  similarity          NUMERIC(6,5) NOT NULL CHECK (similarity BETWEEN -1 AND 1),       -- cosine similarity, 1 = identical
  rank                SMALLINT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (run_id, similar_incident_id)
);
CREATE INDEX IF NOT EXISTS ix_similar_matches_incident ON incident_similar_matches (incident_id);
CREATE INDEX IF NOT EXISTS ix_similar_matches_similar ON incident_similar_matches (similar_incident_id);

CREATE TABLE IF NOT EXISTS recommender_dead_letters (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  topic      TEXT,
  partition  INT,
  "offset"   BIGINT,
  msg_key    TEXT,
  reason     TEXT NOT NULL,
  payload    TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_dead_letter_msg ON recommender_dead_letters (topic, partition, "offset");

-- Convenience view (current run only) ----------------------------------------------------------
CREATE OR REPLACE VIEW v_incident_similar_matches AS
SELECT 'INC-' || i.incident_no AS incident, 'INC-' || si.incident_no AS similar_incident, m.rank, m.similarity,
       si.title AS similar_title, si.status AS similar_status, m.run_id, r.engine, r.created_at AS matched_at,
       m.incident_id, m.similar_incident_id
  FROM incident_suggestion_runs r
  JOIN incident_similar_matches m ON m.run_id = r.id
  JOIN incidents i ON i.id = m.incident_id
  JOIN incidents si ON si.id = m.similar_incident_id
 WHERE r.is_current;

-- ====================================================================================================
-- PART 4: AI PLANNER TABLES (engine ai-planner, Gemini Flash)
-- Source: recommender sql/11_ai_planner.sql
-- ====================================================================================================
ALTER TABLE incident_suggestion_runs DROP CONSTRAINT IF EXISTS incident_suggestion_runs_status_check;
ALTER TABLE incident_suggestion_runs ADD CONSTRAINT incident_suggestion_runs_status_check
  CHECK (status IN ('COMPLETED','NO_MATCH','SUPERSEDED','FAILED'));

CREATE TABLE IF NOT EXISTS incident_ai_plans (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id              UUID NOT NULL UNIQUE REFERENCES incident_suggestion_runs(id) ON DELETE CASCADE,
  incident_id         UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  outcome             TEXT NOT NULL CHECK (outcome IN ('FULL_PLAN','PARTIAL_PLAN','NO_MATCH','FAILED')),
  confidence          NUMERIC(4,3) CHECK (confidence BETWEEN 0 AND 1),
  rationale           TEXT,
  error               TEXT,                                   -- why the run FAILED (validation errors, ...)
  llm_model           TEXT NOT NULL,
  prompt_version      TEXT NOT NULL,
  input_hash          TEXT NOT NULL,                          -- same input -> the previous answer is reused, no LLM call
  catalog_size        INT NOT NULL DEFAULT 0,
  tokens_in           INT,
  tokens_out          INT,
  reused_from_plan_id UUID REFERENCES incident_ai_plans(id) ON DELETE SET NULL,
  review_status       TEXT NOT NULL DEFAULT 'NEW' CHECK (review_status IN ('NEW','APPLIED','DISMISSED')),
  reviewed_by         UUID REFERENCES users(id),
  review_comment      TEXT,
  reviewed_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_ai_plans_incident ON incident_ai_plans (incident_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_ai_plans_hash ON incident_ai_plans (incident_id, input_hash);

CREATE TABLE IF NOT EXISTS incident_ai_plan_steps (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id             UUID NOT NULL REFERENCES incident_ai_plans(id) ON DELETE CASCADE,
  step_no             SMALLINT NOT NULL CHECK (step_no > 0),
  solution_id         UUID NOT NULL REFERENCES solutions(id) ON DELETE CASCADE,
  solution_version_id UUID NOT NULL REFERENCES solution_versions(id) ON DELETE CASCADE,   -- APPROVED when suggested
  on_failure          TEXT NOT NULL DEFAULT 'STOP_ASSET' CHECK (on_failure IN ('STOP_ASSET','CONTINUE','STOP_ALL')),
  reason              TEXT,
  UNIQUE (plan_id, step_no),
  UNIQUE (plan_id, solution_id)
);

CREATE TABLE IF NOT EXISTS ai_solution_drafts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id             UUID NOT NULL REFERENCES incident_ai_plans(id) ON DELETE CASCADE,
  incident_id         UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  position_after_step SMALLINT NOT NULL DEFAULT 0 CHECK (position_after_step >= 0),     -- 0 = before step 1
  title               TEXT NOT NULL,
  problem             TEXT NOT NULL,                          -- what the approved catalog does not cover
  executor            TEXT NOT NULL CHECK (executor IN ('ANSIBLE','AWS_SSM','SHELL','HTTP')),
  applies_to          TEXT,
  proposed_procedure  JSONB NOT NULL DEFAULT '[]',            -- ["step 1 in plain words", ...] - never a job_spec
  risk_level          TEXT NOT NULL DEFAULT 'MEDIUM' CHECK (risk_level IN ('LOW','MEDIUM','HIGH')),
  requires_reboot     BOOLEAN NOT NULL DEFAULT FALSE,
  status              TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_DEVELOPMENT','CREATED','REJECTED')),
  created_solution_id UUID REFERENCES solutions(id) ON DELETE SET NULL,
  updated_by          UUID REFERENCES users(id),
  updated_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_ai_drafts_plan ON ai_solution_drafts (plan_id);
CREATE INDEX IF NOT EXISTS ix_ai_drafts_open ON ai_solution_drafts (status) WHERE status IN ('OPEN','IN_DEVELOPMENT');

-- ====================================================================================================
-- PART 5: CHAT HISTORY (schema bulwark_chat)
-- Source: bulwark-chat-agent sql/01_chat_history.sql
-- Undo (deletes all saved chats):  DROP SCHEMA bulwark_chat CASCADE;
-- ====================================================================================================
CREATE SCHEMA IF NOT EXISTS bulwark_chat;
SET search_path TO bulwark_chat;

-- ---------------------------------------------------------------------------------------------
-- 1. "Recent chats": one row per conversation and user.
--    user_key = 'sub:<JWT subject>' (verified with BULWARK_JWT_SECRET), or 'tok:<token hash>' when no secret is configured.
--    thread_id is the id the UI uses; the conversation state below is stored under '<user_key>:<thread_id>'.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_threads (
    user_key    TEXT        NOT NULL,
    thread_id   TEXT        NOT NULL,
    title       TEXT        NOT NULL,                    -- first question, max 80 characters
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_key, thread_id)
);
CREATE INDEX IF NOT EXISTS chat_threads_recent_idx ON chat_threads (user_key, updated_at DESC);

COMMENT ON TABLE chat_threads IS 'Bulwark Assistant: saved conversations per user (Recent chats)';

-- ---------------------------------------------------------------------------------------------
-- 2. Conversation state: the LangGraph Postgres checkpointer tables (langgraph-checkpoint-postgres 3.x).
--    Messages, tool calls/results and a change still waiting for approval are all in here.
--    Same DDL as the library's own migrations 0-9; they are marked as applied in checkpoint_migrations,
--    so the application never has to create or alter tables itself.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS checkpoint_migrations (
    v INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS checkpoints (
    thread_id            TEXT  NOT NULL,
    checkpoint_ns        TEXT  NOT NULL DEFAULT '',
    checkpoint_id        TEXT  NOT NULL,
    parent_checkpoint_id TEXT,
    type                 TEXT,
    checkpoint           JSONB NOT NULL,
    metadata             JSONB NOT NULL DEFAULT '{}',
    PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id)
);

CREATE TABLE IF NOT EXISTS checkpoint_blobs (
    thread_id     TEXT  NOT NULL,
    checkpoint_ns TEXT  NOT NULL DEFAULT '',
    channel       TEXT  NOT NULL,
    version       TEXT  NOT NULL,
    type          TEXT  NOT NULL,
    blob          BYTEA,
    PRIMARY KEY (thread_id, checkpoint_ns, channel, version)
);

CREATE TABLE IF NOT EXISTS checkpoint_writes (
    thread_id     TEXT    NOT NULL,
    checkpoint_ns TEXT    NOT NULL DEFAULT '',
    checkpoint_id TEXT    NOT NULL,
    task_id       TEXT    NOT NULL,
    idx           INTEGER NOT NULL,
    channel       TEXT    NOT NULL,
    type          TEXT,
    blob          BYTEA   NOT NULL,
    task_path     TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id, task_id, idx)
);

CREATE INDEX IF NOT EXISTS checkpoints_thread_id_idx       ON checkpoints (thread_id);
CREATE INDEX IF NOT EXISTS checkpoint_blobs_thread_id_idx  ON checkpoint_blobs (thread_id);
CREATE INDEX IF NOT EXISTS checkpoint_writes_thread_id_idx ON checkpoint_writes (thread_id);

INSERT INTO checkpoint_migrations (v) SELECT generate_series(0, 9) ON CONFLICT (v) DO NOTHING;

RESET search_path;

-- END OF CONSOLIDATED DDL
