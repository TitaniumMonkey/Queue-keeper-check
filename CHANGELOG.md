# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-10-22

First public release, and the first version published to Hex. 0.1.0 (below) was an
internal milestone: it was never tagged, released or published, and it had the
production-safety problems listed under "Fixed" (see the findings QK-01 to QK-11 in
`docs/SECURITY_REVIEW.md`). If you pinned a pre-release commit from GitHub, read
"Changed" before upgrading.

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
- CI on PostgreSQL 17, SQLite and MySQL 8.4, with actions pinned to commit SHAs and
  `mix hex.audit` (QK-09).

### Changed

- `:retry_storm` counts completed retried jobs only with `include_completed: true`
  (that part needs a full table scan).
- `Release.check/2` never raises, starts the repo with a pool of 1 and stops it afterwards.
- Running `QueueKeeperCheck.run/2` inside an open transaction on Postgres is refused.
- Errors (bad options, database unreachable, timeouts) now exit with 3 instead of 1, so
  "could not check" is no longer reported as "warning" (QK-04).
- Unknown or invalid options raise `ArgumentError` instead of being ignored (QK-06).

### Known limitations

- `:cron_missing` (opt-in) needs a sequential scan; it is bounded by `:statement_timeout` (QK-10).
- On MySQL and SQLite, read-only enforcement depends on a SELECT-only database user or a
  read-only connection; the library only issues `SELECT`s (QK-11).

## [0.1.0] - 2026-10-22 (never published)

Initial implementation. Not tagged, released or published; superseded by 0.2.0.


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

[Unreleased]: https://github.com/TitaniumMonkey/Queue-keeper-check/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/TitaniumMonkey/Queue-keeper-check/releases/tag/v0.2.0
[0.1.0]: https://github.com/TitaniumMonkey/Queue-keeper-check/commit/48b75a1
