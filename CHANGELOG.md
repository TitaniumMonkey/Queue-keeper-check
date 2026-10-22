# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
