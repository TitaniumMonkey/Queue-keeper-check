# queue_keeper_check: security and production-safety review

| | |
|---|---|
| Subject | `queue_keeper_check`, read-only Oban queue health check (Elixir library, Mix task, release entry point) |
| Reviewed code | `main` after commit `16a7c3f` (fixes) on top of v0.1.0 (`56a61fd`) |
| Review date | 2026-10-22 |
| Audience | Security reviewers and senior engineers deciding whether to install it in an application |
| Method | Source reading of every module, plus tests and measurements on PostgreSQL 17.11, SQLite 3.54.1 and MySQL 8.4.9. Every statement below marked **Verified** has a test or a saved output in this repository; anything else is marked **Assumption** or **Not verified**. |

## 1. Summary

The library runs `SELECT` queries against Oban's `oban_jobs` table and returns a report.
v0.1.0 had two high-severity production-safety problems: the Mix task booted the whole
host application (so Oban started, ran jobs and wrote rows), and several queries could
run for minutes on a large table. Both are fixed on `main`, together with server-side
read-only and timeout guards, error handling with a dedicated exit code, input validation
and output sanitisation.

On a 10-million-row `oban_jobs` table with only Oban's standard indexes, a full run took
**about 12 minutes on v0.1.0** and **2.2 s warm / 6.0 s with the OS page cache dropped on
`main`** (section 8). One opt-in check (`:cron_missing`) still needs a sequential scan.

| ID | Severity | Finding | Status |
|---|---|---|---|
| QK-01 | High | `mix queue_keeper.check` started the host application, including Oban queues and plugins, which wrote to the database | Fixed |
| QK-02 | High | Queries that walk the whole table (`ORDER BY id LIMIT 10` samples, sequential scans), run once per finding. About 12 min per run at 10M rows | Fixed |
| QK-03 | Medium | No server-side read-only enforcement, statement timeout or lock timeout. Long reads hold `AccessShareLock`, so a migration waiting behind them blocks every Oban query | Fixed (Postgres: all three; MySQL: execution time only; SQLite: client timeout only) |
| QK-04 | Medium | Failures raised or crashed (`MatchError`, adapter exceptions). The Mix task's error exit code (1) was the same as "warning". `Release.check/2` left the repo running | Fixed |
| QK-05 | Low | Queue and worker names from the database were printed raw. Newlines, ANSI escapes and bidi overrides could forge report lines, and `<!channel>` or links reached Slack payloads | Fixed |
| QK-06 | Low | Options were not validated: typos were ignored silently, and `:prefix` relied only on Ecto's identifier quoting | Fixed (allow-list) |
| QK-07 | Low | All `executing` rows were loaded into memory in the caller (unbounded if many orphans) | Fixed (SQL aggregates) |
| QK-08 | Info | `sample_ids` printed as a charlist (`~c"\a\b\t\n\v\f"`) when ids were small | Fixed |
| QK-09 | Info | CI actions pinned by mutable tag; no `hex.audit`; MySQL not in CI | Fixed |
| QK-10 | Info | `:cron_missing` (opt-in) needs a sequential scan (no index on `worker`/`inserted_at`) | Open, documented, bounded by `statement_timeout` |
| QK-11 | Info | Read-only enforcement on MySQL and SQLite depends on database grants or a read-only connection, not on the library | Open, documented and tested (section 5) |

## 2. Scope and threat model

**In scope:** `lib/` (what ships in the package): `QueueKeeperCheck`, `Checks`, `Config`,
`Guard`, `Report`, `Finding`, `Release`, `Mix.Tasks.QueueKeeper.Check`; its runtime
dependencies; and its behaviour on Postgres (Oban Basic engine), SQLite (Lite) and
MySQL 8.4 (Dolphin).

**Out of scope:** Oban, Ecto, adapters and database servers; Oban Pro; the `dev/`,
`bench/` and `test/` code (never packaged, see `package.files` in `mix.exs`).

**Assets:** the job data in `oban_jobs` (args, meta and errors may hold PII or secrets),
database credentials, availability of the database and of Oban, and the integrity of
alerts.

**Adversaries and misuse considered:**

1. Anyone who can insert a job (and therefore choose a queue or worker string) trying to
   inject SQL, forge alert output, or trigger mentions in Slack.
2. A developer or operator misconfiguring the check (wrong prefix, typo'd thresholds,
   running it inside a transaction, pointing it at production from a laptop).
3. The check itself as a hazard: writing data, starting Oban, taking locks, running heavy
   queries on a large production table, leaking data or credentials into logs or alerts,
   making network calls.
4. Supply chain: dependencies, CI.

## 3. What it starts, and egress

**Verified** with `dev/verify_host_app.sh`, which builds `dev/host_app`: a real app with a
Repo, Oban (a queue, the Cron plugin and the Pruner), and an `Application.start/2` that
prints `HOST_APP_STARTED` and inserts a job. Saved outputs:
[`docs/evidence/host_app_current.txt`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/host_app_current.txt) and
[`docs/evidence/host_app_v0.1.0.txt`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/host_app_v0.1.0.txt).

| | v0.1.0 | `main` |
|---|---|---|
| `mix queue_keeper.check --repo HostApp.Repo` | `HOST_APP_STARTED`; rows went from 6 jobs / 0 peers to **7 jobs / 1 peer** | app not started; rows unchanged |
| `bin/host_app eval 'QueueKeeperCheck.Release.main(...)'` (real `mix release`) | app not started; rows unchanged | app not started; rows unchanged |
| Running after `Release.check/2` | host repo left running | started apps: `asn1 compiler crypto db_connection decimal ecto ecto_sql eex elixir jason kernel logger postgrex public_key ssl stdlib telemetry`. `host_app` and `oban` not started, `Oban.Registry` not running, repo stopped again |

The Mix task now runs `app.config` (compile, then load config including `runtime.exs`)
and then `Release.check/2`, which starts only the adapter applications and the repo
(`pool_size: 1`, unlinked, stopped afterwards). When the repo is already running (the
check is called from inside the app), the host's pool is reused and nothing new starts.

**Network and files (Verified, release run under `strace -f -e connect,openat`):** the only
`connect()` targets were `127.0.0.1:5432` (the database) and the local nscd socket, used
for resolving `localhost`. The only file opened for writing was `/dev/null`. The library
contains no HTTP client, no `:httpc`/`:gen_tcp`/`:ssl` use, and no telemetry exporter.
`slack_payload/1` only builds a map; sending it is up to the caller.
**Not verified:** the same strace for the Mix task path. Mix also compiles the project,
which writes to `_build`.

Ecto emits its usual in-VM `[:my_app, :repo, :query]` telemetry and debug logs for these
queries, including the SQL and the parameters (timestamps, queue and worker names; never
job data). If the host app forwards Ecto telemetry to an APM, these queries appear there.

## 4. Exact SQL issued

Complete per-engine dumps, captured from telemetry while a test makes every check fire:
[`postgres.sql`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/sql/postgres.sql), [`myxql.sql`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/sql/myxql.sql),
[`sqlite3.sql`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/sql/sqlite3.sql). The distinct Postgres statement shapes (`$n` =
bound parameter) are:

```sql
-- guard, once per check (Postgres)
begin
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $n, true),
       set_config('lock_timeout', $n, true), set_config('idle_in_transaction_session_timeout', $n, true)
rollback
-- orphaned / hanging (aggregates, plus a LIMIT 10 id sample per finding)
SELECT queue, worker, count(id), min(attempted_at) FROM oban_jobs WHERE state = 'executing' AND attempted_at <= $n GROUP BY queue, worker ORDER BY queue, worker
SELECT queue, worker, count(id), min(attempted_at) FROM oban_jobs WHERE state = 'executing' AND attempted_at > $n AND attempted_at <= $n AND [NOT] (worker = ANY($n)) GROUP BY queue, worker ORDER BY queue, worker
-- backlog / stalled (one aggregate shared by both checks)
SELECT queue, count(id), min(scheduled_at) FROM oban_jobs WHERE state IN ('available','scheduled','retryable') AND (state = 'available' OR scheduled_at <= $n) GROUP BY queue ORDER BY queue
-- stalled: per late queue only, LIMIT 1 probes, cheapest first
SELECT id FROM oban_jobs WHERE state = 'executing' AND attempted_at >= $n AND queue = $n LIMIT 1
SELECT id FROM oban_jobs WHERE state IN ('scheduled','retryable') AND scheduled_at >= $n AND attempted_at >= $n AND queue = $n LIMIT 1
SELECT id FROM oban_jobs WHERE state = 'discarded' AND discarded_at >= $n AND queue = $n LIMIT 1
SELECT id FROM oban_jobs WHERE state = 'cancelled' AND cancelled_at >= $n AND queue = $n LIMIT 1
SELECT id FROM oban_jobs WHERE state = 'completed' AND scheduled_at >= $n AND attempted_at >= $n AND queue = $n LIMIT 1
-- retry_storm (the completed part only with include_completed: true; the retryable part has been
-- windowed since the release after v0.2.0, before that it was `WHERE state = 'retryable'`)
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = 'retryable' AND scheduled_at >= $n AND attempted_at >= $n GROUP BY worker, queue
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = 'executing' AND attempt >= 2 AND attempted_at >= $n GROUP BY worker, queue
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = 'discarded' AND discarded_at >= $n AND attempt >= 2 GROUP BY worker, queue
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = 'cancelled' AND cancelled_at >= $n AND attempt >= 2 GROUP BY worker, queue
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = 'completed' AND attempt >= 2 AND attempted_at >= $n GROUP BY worker, queue
-- discarded / cancelled spikes
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = $n AND discarded_at >= $n GROUP BY worker, queue
SELECT worker, queue, count(id) FROM oban_jobs WHERE state = $n AND cancelled_at >= $n GROUP BY worker, queue
-- cron_missing (opt-in)
SELECT worker, max(inserted_at), max(id) FROM oban_jobs WHERE worker = ANY($n) GROUP BY worker
-- samples: the finding's own WHERE clause plus queue/worker equality, `SELECT id ... LIMIT 10`
-- (no ORDER BY), at most 100 sample queries per run
```

MySQL issues the same queries (backtick quoting, `?` parameters, `CAST(... AS
datetime(6))`) and wraps each check in `SELECT @@SESSION.max_execution_time`,
`SET SESSION max_execution_time = ?` and a restore of the previous value. SQLite issues
the queries only.

**Verified by `test "statement audit ..."`** (runs on all three engines): every
statement is a `SELECT` or `begin`/`rollback` (plus the MySQL `SET SESSION
max_execution_time`). None contains `INSERT`, `UPDATE`, `DELETE`, `MERGE`, DDL, `LOCK`,
`FOR UPDATE/SHARE`, `nextval` or advisory-lock functions. Every column referenced is in
{`id`, `state`, `queue`, `worker`, `attempt`, `inserted_at`, `scheduled_at`,
`attempted_at`, `discarded_at`, `cancelled_at`}. Only `oban_jobs` is read: `oban_peers`
and `oban_producers` are never touched.

**Locks.** A plain `SELECT` takes `AccessShareLock` on Postgres (and a shared metadata
lock on MySQL). Those conflict only with `ACCESS EXCLUSIVE` (DDL, `VACUUM FULL`, `LOCK
TABLE`). **Verified:** while a check held a 1-second query on the table,
`UPDATE`/`INSERT`/`DELETE` from another connection completed in under 500 ms (test
"a long-running check does not block Oban's row writes"). With `lock_timeout` set to
100 ms, a check facing an `ACCESS EXCLUSIVE` lock gave up in under 5 s for all 7 checks
instead of queueing (test "lock_timeout ...").

## 5. Required database privileges

The library needs **read access to `oban_jobs` only**. Recommended least-privilege setup:

```sql
-- PostgreSQL (verified by test "works under a least-privilege role")
CREATE ROLE queue_keeper_check LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE my_db TO queue_keeper_check;
GRANT USAGE ON SCHEMA public TO queue_keeper_check;          -- or your Oban prefix
GRANT SELECT ON public.oban_jobs TO queue_keeper_check;
ALTER ROLE queue_keeper_check SET statement_timeout = '5s';   -- belt and braces
ALTER ROLE queue_keeper_check SET default_transaction_read_only = on;

-- MySQL 8.4 (verified by test "works under a SELECT-only MySQL user")
CREATE USER 'queue_keeper_check'@'%' IDENTIFIED BY '...';
GRANT SELECT ON my_db.oban_jobs TO 'queue_keeper_check'@'%';
```

SQLite: open the database read-only with a dedicated repo (`mode: :readonly` in
`ecto_sqlite3`). **Verified** (test "works on a SQLite database opened read-only").

The tests also confirm the role cannot write (`permission denied` / `denied` /
`readonly database`) and, on Postgres, cannot read other tables. The two
`ALTER ROLE ... SET` lines are a recommendation and were not separately tested.

**Server-side read-only on Postgres even without a dedicated role (Verified):** each check
runs in its own transaction marked `transaction_read_only`, which is always rolled back.
A write attempted inside the guard fails with `read_only_sql_transaction` (test "the
guard makes the server reject writes"). The settings are transaction-local, so they
cannot leak into a pooled connection. Calling `run/2` inside the caller's open
transaction is refused, because the settings would apply to the caller's transaction;
the caller's transaction stays usable (tested).

## 6. Data touched and never touched

| | Columns |
|---|---|
| Read | `id`, `state`, `queue`, `worker`, `attempt`, `inserted_at`, `scheduled_at`, `attempted_at`, `discarded_at`, `cancelled_at` |
| Never read (not selected, not filtered on) | `args`, `meta`, `errors`, `tags`, `attempted_by`, `priority`, `max_attempts`, `completed_at` |
| Appears in output | check name, severity, queue name, worker name, counts, ages and thresholds in seconds, up to 10 job ids per finding, error class plus the first line of the error message (at most 300 characters) |

**Verified** (test "data exposure"): with every check firing and an email address, a card
number and a token placed in `args`, `meta` and `errors`, none of them appears in
`format/1`, the JSON encoding, `inspect/1` of the report, or the Slack payload. The
database-down and wrong-password tests confirm the configured passwords appear in neither
the report nor the captured logs. The connection error that the adapter logs names the
host and port (`tcp connect (127.0.0.1:1): connection refused`) or the user
(`password authentication failed for user "postgres"`), but not the password.

Queue and worker names can be sensitive in themselves (for example
`MyApp.Workers.ExportPatientRecords`). They appear in every finding. Decide where reports
go with that in mind.

## 7. Injection and output integrity

* **SQL:** every value (thresholds turned into timestamps, queue names, worker names,
  budgets) is a bound parameter; nothing user-supplied is interpolated into SQL text. The
  only identifier is `:prefix`. Ecto already quotes it and rejects `"` (Postgres) or
  `` ` `` (MySQL). It is now also restricted to `[A-Za-z_][A-Za-z0-9_]{0,62}` (or `false`
  for no prefix). The only string interpolation in library SQL is the fixed list of
  setting names in `Guard`. **Verified:** a job with the queue
  `q'); DROP TABLE oban_jobs; --` is reported as a normal queue and the table remains;
  bad prefixes, thresholds and unknown keys raise `ArgumentError` before any query is
  issued (the test asserts zero statements); `Release.check/2` turns them into exit code 3.
* **Text output:** `format/1` replaces Unicode control (Cc) and format (Cf) characters
  with `?`, which covers newlines, ESC/ANSI sequences, U+202E and zero-width characters.
  A crafted worker name therefore cannot add or reorder lines. **Verified** by test
  "hostile queue/worker names".
* **Slack:** `slack_payload/1` escapes `&`, `<` and `>`, so `<!channel>` and
  `<https://...|x>` arrive as literal text. **Verified** by the same test.
* JSON output uses Jason's standard escaping. Names are passed through unchanged; a
  consumer that renders them must escape them itself.

## 8. Performance and safety at scale

**Environment (Postgres).** Shared cloud VM (other workloads were running): 8 vCPU Intel
Xeon, 16 GB RAM, local virtual disk. PostgreSQL 17.11 with default settings
(`shared_buffers` 128 MB, `work_mem` 4 MB, 2 parallel workers per gather). Treat the
numbers as relative, not as a benchmark of your hardware.

**Dataset.** `bench/setup_pg.exs`: 10,000,000 rows, 6.0 GB including indexes, created with
`Oban.Migration.up()` (Postgres migrations v1-v14), so only Oban's standard indexes exist:
`(state, queue, priority, scheduled_at, id)`, `(state, discarded_at)`,
`(state, cancelled_at)`, GIN on `args` and `meta`, and the primary key. State mix:
9.0M completed (30 days of history, 5% retried), 400k available (8 queues, up to 2 h
old), 300k discarded, 200k cancelled, 80k scheduled, 19k retryable, 1k executing. 40
queues and 250 workers. The data was frozen at seed time, so when measured every queue
had overdue jobs and no recent attempts. That is the worst case for `:stalled` (every
queue is probed). Default thresholds plus `cron_missing` for one frequent worker and one
never-seen worker.

| Check | v0.1.0 (one run) | `main`, warm (median of 3) | `main`, OS page cache dropped (one run) |
|---|---|---|---|
| orphaned | 27.9 ms | 8.7 ms | 119 ms |
| hanging | 4.7 ms | 9.1 ms | 114 ms |
| backlog | **86,821 ms** | 47.4 ms | 151 ms |
| stalled | **87,972 ms** | 1,682 ms (40 late queues probed) | 4,924 ms |
| retry_storm | **549,476 ms** | 42.8 ms | 148 ms |
| discarded | 4.0 ms | 2.0 ms | 90 ms |
| cancelled | 2.2 ms | 1.1 ms | 85 ms |
| cron_missing (opt-in) | 573 ms | 487 ms (parallel seq scan) | 2,413 ms |
| **full run** | **≈ 725 s** (sum of the above) | **2.24 s**, 334 statements; 2.23 s with default limits, 0 errors | **5.97 s**, 0 errors |

"Page cache dropped" means `echo 3 > /proc/sys/vm/drop_caches` before each run, with
Postgres not restarted (its 128 MB of shared buffers stayed warm). Raw outputs and every
`EXPLAIN (ANALYZE, BUFFERS)` are in [`docs/evidence/perf/`](https://github.com/TitaniumMonkey/Queue-keeper-check/tree/v0.2.0/docs/evidence/perf)
(`pg_summary.txt`, `pg_explain.txt`, `pg_v0.1.0_baseline_*.txt`).

**Re-run after the windowed `retry_storm` change (Unreleased, 2026-10-22, same box and
database, one warm run):** `retry_storm` 16.3 ms; full run 1.62 s, 209 statements, 131
findings (was 1,331: retryable jobs whose failure falls outside the window no longer count);
1.58 s with default limits, 0 errors. The retryable branch uses the composite index with
`Index Cond: state = 'retryable' AND scheduled_at >= ...` and filters on `attempted_at`; no
sequential scans other than the opt-in `:cron_missing`. Raw output:
`docs/evidence/perf/pg_unreleased_retry_window_{summary,explain}.txt`. The table above
was not re-measured.

**Root causes in v0.1.0 (from the saved plans):** sample queries
`... ORDER BY id LIMIT 10` made the planner walk the primary key, filtering 9.5M rows
(2.4 s and 401k buffers per call), and they ran once per finding (about 250 times for
`retry_storm` alone). The `retry_storm` aggregate (`state = 'retryable' OR attempt >= 2
AND attempted_at >= ...`) and the `stalled` activity query were sequential scans. By
code reading, the latter also ran when there were no late queues.

**Plans on `main`:** every statement uses an index except `:cron_missing` (sequential
scan, 0.5 s warm). With an optional, application-owned index
`CREATE INDEX CONCURRENTLY ... ON oban_jobs (worker, inserted_at)` the same query took
118 ms ([`pg_cron_missing_with_optional_index.txt`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/perf/pg_cron_missing_with_optional_index.txt));
the index was dropped afterwards and is not required.

**Bounds now in place:** each query is either an aggregate (one row per queue or worker)
or `LIMIT 1`/`LIMIT 10`. The `stalled` probes run only for late queues and are bounded
by an index range. There are at most 100 sample queries per run. `retry_storm` counts
completed jobs (a full scan) only with `include_completed: true`. Per-statement
`statement_timeout` (default 5 s), `lock_timeout` (1 s) and
`idle_in_transaction_session_timeout` (2 × statement_timeout) apply, plus a client-side
per-query timeout (statement_timeout + 2 s) and a per-check budget (`check_timeout`,
30 s). All are configurable. When a limit fires, that check is reported as an error
(exit code 3) and the other checks still run (tested).

**MySQL 8.4.9 and SQLite 3.54.1 (lighter run, `bench/light.exs`, 1,000,000 rows, same
mix, same box):**

| Check | MySQL 8.4.9 | SQLite 3.54.1 |
|---|---|---|
| orphaned | 92.0 ms | 0.7 ms |
| hanging | 90.4 ms | 0.1 ms |
| backlog | 123.0 ms | 17.2 ms |
| stalled | 153.3 ms | 21.5 ms |
| retry_storm | 170.7 ms | 19.6 ms |
| discarded | 130.6 ms | 8.7 ms |
| cancelled | 115.9 ms | 6.0 ms |
| cron_missing | 577.2 ms (table scan) | 100.7 ms (table scan) |
| full run | 1.58 s | 0.17 s |

Both engines have only the composite `(state, queue, priority, scheduled_at, id)` index
from Oban, so discarded/cancelled windows are read through the state prefix. In
`EXPLAIN ANALYZE` / `EXPLAIN QUERY PLAN`, every statement except `:cron_missing` used
that index ([`mysql_explain.txt`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/perf/mysql_explain.txt),
[`sqlite_explain.txt`](https://github.com/TitaniumMonkey/Queue-keeper-check/blob/v0.2.0/docs/evidence/perf/sqlite_explain.txt)). The roughly 90 ms floor per
check on MySQL was not investigated further.

## 9. Failure behaviour

| Situation | Result | Evidence |
|---|---|---|
| Database down (nothing listening) | exit 3; first check reports "no database connection became available ..."; remaining checks marked skipped; under 10 s; repo stopped | test "database down" |
| Wrong password | exit 3; password not in report or logs | test "wrong password" |
| Statement exceeds `statement_timeout` | that check errors with `query_canceled`; others run | test "statement_timeout is enforced" |
| Exclusive lock held on the table | each check errors with `lock_not_available` after `lock_timeout` | test "lock_timeout ..." |
| Missing table / wrong prefix | exit 3; 7 checks report `undefined_table` | test "prefix mismatch" |
| Older Oban schema (no `discarded_at`/`cancelled_at`) | `discarded`, `cancelled` and `retry_storm` report `undefined_column`; the other checks still produce results | test "older Oban schema" |
| Called inside the caller's transaction (Postgres) | status `:error`, nothing executed; caller's transaction unaffected | test "refuses to run inside ..." |
| Invalid options | `run/2` raises `ArgumentError` before any query; `Release.check/2` and the Mix task return exit 3 | tests "config validation", "Release.check turns bad options ..." |
| Unknown repo module | exit 3 | same test |

`run/2` never raises for database errors. It raises only for programming errors at the
call site: `ArgumentError` for invalid options, or an error if `repo` is not an Ecto repo. `Release.check/2` never raises.

Exit codes: 0 ok, 1 warning, 2 critical, 3 error (unknown). If any finding is critical,
the status is critical even when other checks failed.

## 10. Dependencies and supply chain

Runtime dependencies are `oban ~> 2.18`, `ecto_sql ~> 3.10` and `jason ~> 1.4`, plus
their transitive deps `ecto`, `db_connection`, `telemetry` and `decimal`. Oban itself
depends on `ecto_sql`, `jason` and `telemetry`, so **an application that already uses
Oban gets no new packages**. Database adapters come from the host (`postgrex`, `myxql`
and `ecto_sqlite3` are test-only here).

| Package | Locked version | License |
|---|---|---|
| oban | 2.24.2 | Apache-2.0 |
| ecto_sql | 3.14.0 | Apache-2.0 |
| ecto | 3.14.2 | Apache-2.0 |
| db_connection | 2.10.2 | Apache-2.0 |
| telemetry | 1.4.2 | Apache-2.0 |
| decimal | 3.2.0 | Apache-2.0 |
| jason | 1.4.5 | Apache-2.0 |
| postgrex / myxql (test) | 0.22.4 / 0.9.0 | Apache-2.0 |
| ecto_sqlite3 / exqlite (test; exqlite builds or downloads a NIF) | 0.26.0 / 0.43.0 | MIT |
| this library | | MIT |

Tool results (2026-10-22), run in a throwaway copy so the repository's dependency list is
unchanged:

* `mix hex.audit`: "No retired or security advisory packages found".
* `mix deps.audit` (mix_audit 2.1): "No vulnerabilities found".
* `mix sobelow --skip -v` (0.16.0): no findings. Sobelow targets Phoenix, so only its
  generic checks apply here.
* `mix credo --strict`: style and design suggestions only (nesting depth, missing
  `@moduledoc` on test repos); none security-relevant.
* `mix dialyzer` (with `:mix` in the PLT): 0 errors.

CI (`.github/workflows/ci.yml`): actions pinned to commit SHAs, `permissions: contents:
read`, and `hex.audit`, format, `--warnings-as-errors` compile and the full test suite
on Postgres 17, SQLite and MySQL 8.4. `mix.lock` records the Hex checksums.

The README installs from GitHub. A git tag can be moved, so pin a commit with
`ref: "<sha>"` in your `mix.exs`.

## 11. Residual risks and limitations

* **`:cron_missing` costs a sequential scan** on all engines (QK-10). It is opt-in and
  bounded by `statement_timeout`; a timeout makes it report an error, not a false "ok".
  If you enable it on a large table, consider your own `(worker, inserted_at)` index.
* **MySQL and SQLite read-only enforcement** relies on grants or `mode: :readonly`
  (QK-11). The library issues only `SELECT`s (audited), but nothing on the server side
  stops a write if that ever changed. On MySQL, `max_execution_time` is set per session
  and restored after each check. If the check process dies mid-check, DBConnection
  disconnects that connection (source-verified in `db_connection` 2.10.2), so the
  setting does not return to the pool. If the restore statement itself failed on a
  still-healthy connection, the setting would remain on that pooled connection; not
  tested.
* **SQLite** has no server-side timeouts. With the rollback journal (not WAL), a long
  read blocks writers. `ecto_sqlite3` uses WAL by default (per its documentation).
* **Behaviour changes in `main`:**
  * `:retry_storm` no longer counts completed retried jobs unless `include_completed: true`.
  * `:stalled` treats completed jobs as activity only if they were scheduled at most
    `lookback` seconds (default 3600) before the queue's oldest due job. A queue whose
    only recent work is jobs that waited much longer than that is reported as stalled,
    and it is then also a critical backlog.
* **The Mix task compiles the host project** and loads its config, including
  `runtime.exs`. Starting the repo runs the repo's own `init/2` and any `after_connect`.
  That is host code, not this library's.
* **Logs and telemetry:** Ecto debug logs and query telemetry carry the SQL with queue
  and worker names and timestamps (section 3).
* **`:stalled` worst case** grows with the number of late queues (about 40-120 ms per
  queue here). The whole check is capped by `check_timeout`.

## 12. Not verified

* GitHub Actions runs of the updated workflow (not observed at the time of writing).
* PgBouncer (transaction or statement pooling), read replicas or hot standbys,
  PostgreSQL versions other than 17.11, MySQL other than 8.4.9, MariaDB (unsupported by
  Oban), Oban Pro tables or partitioned `oban_jobs`, Oban versions other than 2.24.2 (an
  older schema was only simulated by dropping columns), Elixir/OTP other than 1.18.3/27.
* MySQL and SQLite beyond 1M rows; behaviour under real concurrent Oban load (only
  synthetic concurrent writes and locks); slow network-attached storage.
* The two `ALTER ROLE ... SET` recommendations in section 5; strace of the Mix task path.

## 13. How to run it safely the first time

1. **Pin the code:** depend on a reviewed commit (`ref: "<sha>"`), not a branch or tag.
2. **Create a least-privilege user** (section 5) and a dedicated repo that uses it, for
   example `MyApp.HealthRepo`, with `pool_size: 1`. Never reuse a write-capable admin
   user.
3. **Try it on a staging or local copy** of your database first:

   ```
   mix queue_keeper.check --repo MyApp.HealthRepo --statement-timeout 2000
   echo $?   # 0 ok, 1 warning, 2 critical, 3 error
   ```

   Look at the reported durations in your database's slow-query log or
   `pg_stat_statements`. If `:cron_missing` is enabled, check its sequential scan cost.
4. **Keep the defaults or tighten them:** `statement_timeout: 5_000`,
   `lock_timeout: 1_000`, `check_timeout: 30_000`, `read_only: true`. Leave
   `retry_storm: [include_completed: false]` on large tables.
5. **In production, run it outside the app** (`bin/my_app eval
   'QueueKeeperCheck.Release.main(MyApp.HealthRepo, otp_app: :my_app)'` from cron),
   treat exit code 3 as "check broken", and add an outside heartbeat (README).
6. **Mind where reports go:** they contain queue and worker names and job ids.

## Appendix: reproducing

```
mix test                                   # Postgres + SQLite
QK_MYSQL=1 mix test                        # + MySQL 8.4 on 127.0.0.1:3307 (dev/mysql84.sh)
QK_MYSQL=1 QK_DUMP_SQL=docs/evidence/sql mix test test/queue_keeper_check_test.exs
MIX_ENV=test mix run --no-start bench/setup_pg.exs 10000000   # ~8 min, ~6 GB, database qk_perf
MIX_ENV=test mix run --no-start bench/run_pg.exs docs/evidence/perf
MIX_ENV=test mix run --no-start bench/light.exs mysql 1000000
MIX_ENV=test mix run --no-start bench/light.exs sqlite 1000000
dev/verify_host_app.sh                     # isolation, rows written, strace
```
