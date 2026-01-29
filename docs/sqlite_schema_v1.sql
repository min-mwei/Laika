-- Laika SQLite schema (v1)
--
-- Scope:
-- - Collections, Sources (captured Markdown), Chat history, Artifacts, Capture jobs, and optional LLM usage runs.
--
-- Notes:
-- - Timestamps are Unix epoch milliseconds (INTEGER).
-- - JSON fields are stored as TEXT blobs (validated/parsed in trusted code).
-- - App code should set connection pragmas on open:
--   PRAGMA foreign_keys = ON;
--   PRAGMA journal_mode = WAL;
--   PRAGMA synchronous = NORMAL;
--   PRAGMA busy_timeout = 2000;
--
-- This file is intentionally "plain SQLite" (no JSON1/FTS5 required).

BEGIN;

-- Also mirror the schema version into SQLite's built-in user_version.
-- (App code can read it via `PRAGMA user_version;`.)
PRAGMA user_version = 1;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');

-- ---------------------------------------------------------------------------
-- Collections
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS collections (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'col_%'),
  title TEXT NOT NULL,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_collections_updated_at
  ON collections(updated_at_ms DESC);

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'src_%'),
  collection_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('url', 'note', 'image')),

  url TEXT,
  normalized_url TEXT,
  title TEXT,

  provenance_json TEXT NOT NULL DEFAULT '{}',

  capture_status TEXT NOT NULL DEFAULT 'pending'
    CHECK(capture_status IN ('pending', 'captured', 'failed')),
  capture_version INTEGER NOT NULL DEFAULT 1 CHECK(capture_version >= 1),
  content_hash TEXT,
  capture_error TEXT,
  capture_summary TEXT,
  capture_markdown TEXT,

  extracted_links_json TEXT NOT NULL DEFAULT '[]',
  media_json TEXT NOT NULL DEFAULT '{}',

  added_at_ms INTEGER NOT NULL,
  captured_at_ms INTEGER,
  updated_at_ms INTEGER NOT NULL,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,

  CHECK(kind <> 'url' OR (url IS NOT NULL AND normalized_url IS NOT NULL)),
  CHECK(kind <> 'note' OR (capture_markdown IS NOT NULL))
);

-- Fast list views.
CREATE INDEX IF NOT EXISTS idx_sources_collection_added
  ON sources(collection_id, added_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_sources_collection_status_added
  ON sources(collection_id, capture_status, added_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_sources_collection_captured
  ON sources(collection_id, captured_at_ms DESC);

-- Dedupe: one URL per collection (only for url sources).
CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_unique_normalized_url_per_collection
  ON sources(collection_id, normalized_url)
  WHERE kind = 'url' AND normalized_url IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Capture jobs (queue + retries)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS capture_jobs (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'job_%'),
  collection_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  url TEXT NOT NULL,
  dedupe_key TEXT NOT NULL DEFAULT '',

  status TEXT NOT NULL DEFAULT 'queued'
    CHECK(status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
  max_attempts INTEGER NOT NULL DEFAULT 3 CHECK(max_attempts >= 1),
  last_error TEXT,

  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  started_at_ms INTEGER,
  finished_at_ms INTEGER,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,
  FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_status_updated
  ON capture_jobs(status, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_collection_status
  ON capture_jobs(collection_id, status, created_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_source_status
  ON capture_jobs(source_id, status, updated_at_ms DESC);

-- Only one active job per source at a time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_jobs_one_active_per_source
  ON capture_jobs(source_id)
  WHERE status IN ('queued', 'running');

-- Optional: only one active job per dedupe key at a time (lets app avoid double-scheduling).
CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_jobs_one_active_per_dedupe_key
  ON capture_jobs(dedupe_key)
  WHERE status IN ('queued', 'running') AND dedupe_key <> '';

-- ---------------------------------------------------------------------------
-- Chat events (collection-scoped)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chat_events (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'chat_%'),
  collection_id TEXT NOT NULL,

  role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system')),
  markdown TEXT NOT NULL,
  citations_json TEXT NOT NULL DEFAULT '[]',
  tool_calls_json TEXT NOT NULL DEFAULT '[]',
  tool_results_json TEXT NOT NULL DEFAULT '[]',

  model_json TEXT NOT NULL DEFAULT '{}',

  created_at_ms INTEGER NOT NULL,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chat_events_collection_created
  ON chat_events(collection_id, created_at_ms ASC);

-- ---------------------------------------------------------------------------
-- Artifacts (durable outputs)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS artifacts (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'art_%'),
  collection_id TEXT NOT NULL,

  type TEXT NOT NULL,
  title TEXT NOT NULL,
  dedupe_key TEXT NOT NULL DEFAULT '',

  status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  error TEXT,

  content_markdown TEXT,
  source_ids_json TEXT NOT NULL DEFAULT '[]',
  citations_json TEXT NOT NULL DEFAULT '[]',
  config_json TEXT NOT NULL DEFAULT '{}',

  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  started_at_ms INTEGER,
  finished_at_ms INTEGER,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_artifacts_collection_updated
  ON artifacts(collection_id, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_artifacts_collection_type_updated
  ON artifacts(collection_id, type, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_artifacts_status_updated
  ON artifacts(status, updated_at_ms DESC);

-- Prevent duplicate "active" transform runs that are logically identical.
-- (Completed/failed artifacts can share the same dedupe_key; only pending/running is constrained.)
CREATE UNIQUE INDEX IF NOT EXISTS idx_artifacts_one_active_per_dedupe_key
  ON artifacts(dedupe_key)
  WHERE status IN ('pending', 'running') AND dedupe_key <> '';

-- ---------------------------------------------------------------------------
-- Optional: LLM usage runs (P1, safe to add in v1)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS llm_runs (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'run_%'),
  created_at_ms INTEGER NOT NULL,

  kind TEXT NOT NULL, -- e.g. chat|transform|ranking|summarization|test
  provider_id TEXT,
  model_id TEXT,

  collection_id TEXT,
  source_id TEXT,
  artifact_id TEXT,
  chat_event_id TEXT,

  input_tokens INTEGER,
  output_tokens INTEGER,
  total_tokens INTEGER,
  cost_usd REAL,

  request_redacted_json TEXT NOT NULL DEFAULT '{}',
  response_redacted_json TEXT NOT NULL DEFAULT '{}',
  error TEXT,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE SET NULL,
  FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE SET NULL,
  FOREIGN KEY(artifact_id) REFERENCES artifacts(id) ON DELETE SET NULL,
  FOREIGN KEY(chat_event_id) REFERENCES chat_events(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_llm_runs_created
  ON llm_runs(created_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_llm_runs_collection_created
  ON llm_runs(collection_id, created_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_llm_runs_kind_created
  ON llm_runs(kind, created_at_ms DESC);

COMMIT;
