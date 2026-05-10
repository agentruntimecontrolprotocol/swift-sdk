-- ARCP SQLite event log schema (RFC §19, §6.4).
-- Phase 0: placeholder. Real DDL is introduced in Phase 1 alongside EventLog.swift.

CREATE TABLE IF NOT EXISTS arcp_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
