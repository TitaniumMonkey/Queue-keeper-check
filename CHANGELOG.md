# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Security and production-safety hardening. See `docs/SECURITY_REVIEW.md`.

### Fixed

- `mix queue_keeper.check` no longer starts the host application (and therefore Oban,
  its queues and plugins); it loads config and starts only the repo (QK-01).
- Queries that could take minutes on large tables: sample queries no longer
  `ORDER BY id`; `:orphaned`/`:hanging` aggregate in SQL; `:stalled` probes only late
  queues with index-bounded `LIMIT 1` queries; sample queries capped at 100 per run (QK-02, QK-07).
- Text output replaces control/bidi characters; Slack payloads escape `&`, `<` and `>` (QK-05).
- `sample_ids` no longer render as a charlist (QK-08).

### Added

- `QueueKeeperCheck.Guard`: on Postgres every check runs in a rolled-back transaction with
  `transaction_read_only`, `statement_timeout`, `lock_timeout` and
  `idle_in_transaction_session_timeout`; on MySQL `max_execution_time` (QK-03).
- Options `:statement_timeout` (5000), `:lock_timeout` (1000), `:check_timeout` (30000),
  `:read_only` (true); `stalled: [lookback: 3600]`; `retry_storm: [include_completed: false]`.
- `report.errors`, status `:error` and exit code 3; per-check error isolation; remaining
  checks are skipped after a connection error (QK-04).
- Strict option validation, including an identifier allow-list for `:prefix` (QK-06).
- `SECURITY.md`, `docs/SECURITY_REVIEW.md`, benchmark and verification scripts.

### Changed

- `:retry_storm` counts completed retried jobs only with `include_completed: true`
  (that part needs a full table scan).
- `Release.check/2` never raises, starts the repo with a pool of 1 and stops it afterwards.
- Running `QueueKeeperCheck.run/2` inside an open transaction on Postgres is refused.

## [0.1.0] - 2026-10-22

### Added

- `QueueKeeperCheck.run/2`: read-only checks on `oban_jobs` for `:orphaned`, `:hanging`,
  `:backlog`, `:stalled`, `:retry_storm`, `:discarded`, `:cancelled` and `:cron_missing`,
  with configurable thresholds (`QueueKeeperCheck.Config`).
- `QueueKeeperCheck.format/1` (plain text) and `QueueKeeperCheck.slack_payload/1`
  (Slack incoming-webhook body; never sent by the library).
- `mix queue_keeper.check` task with exit codes 0 (ok), 1 (warning), 2 (critical).
- `QueueKeeperCheck.Release.main/2` / `check/2` for running from a release via `eval`,
  outside Oban (e.g. system cron).
- Support for Oban's Basic (PostgreSQL), Lite (SQLite3) and Dolphin (MySQL 8.4+) engines.

[Unreleased]: https://github.com/TitaniumMonkey/Queue-keeper-check/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/TitaniumMonkey/Queue-keeper-check/releases/tag/v0.1.0
