-- ARCP SQLite event log schema (RFC §6.4 / §13.3 / §19).

CREATE TABLE IF NOT EXISTS arcp_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS arcp_events (
    session_id      TEXT    NOT NULL,
    message_id      TEXT    NOT NULL,
    type_name       TEXT    NOT NULL,
    timestamp       TEXT    NOT NULL,
    job_id          TEXT,
    stream_id       TEXT,
    subscription_id TEXT,
    trace_id        TEXT,
    span_id         TEXT,
    correlation_id  TEXT,
    causation_id    TEXT,
    idempotency_key TEXT,
    priority        TEXT    NOT NULL,
    envelope_json   TEXT    NOT NULL,
    sequence        INTEGER NOT NULL,
    PRIMARY KEY (session_id, message_id)
);

CREATE INDEX IF NOT EXISTS arcp_events_by_session_seq
    ON arcp_events (session_id, sequence);

CREATE INDEX IF NOT EXISTS arcp_events_by_session_job
    ON arcp_events (session_id, job_id, sequence);

CREATE INDEX IF NOT EXISTS arcp_events_by_session_stream
    ON arcp_events (session_id, stream_id, sequence);

CREATE INDEX IF NOT EXISTS arcp_events_by_trace
    ON arcp_events (trace_id, sequence);

CREATE TABLE IF NOT EXISTS arcp_idempotency (
    principal       TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    response_json   TEXT NOT NULL,
    expires_at      TEXT NOT NULL,
    PRIMARY KEY (principal, idempotency_key)
);

CREATE TABLE IF NOT EXISTS arcp_artifacts (
    artifact_id TEXT    PRIMARY KEY,
    session_id  TEXT    NOT NULL,
    media_type  TEXT    NOT NULL,
    size        INTEGER NOT NULL,
    sha256      TEXT,
    expires_at  TEXT,
    body        BLOB    NOT NULL
);
