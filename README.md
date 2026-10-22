# queue_keeper_check

[![CI](https://github.com/TitaniumMonkey/Queue-keeper-check/actions/workflows/ci.yml/badge.svg)](https://github.com/TitaniumMonkey/Queue-keeper-check/actions/workflows/ci.yml)

Read-only health check for [Oban](https://github.com/oban-bg/oban) queues. It runs aggregate
queries on `oban_jobs` and reports eight conditions with thresholds:

| Check | Fires when | Default threshold | Severity |
|---|---|---|---|
| `:orphaned` | a job has been `executing` far longer than any job should run. It measures execution age only: the job may have been orphaned by a node crash, or may genuinely still be running | 3600 s (Oban Lifeline's default `rescue_after`) | always critical |
| `:hanging` | a job is `executing` past its worker's time budget | 300 s, per-worker overrides | warning, critical at 2x |
| `:backlog` | a queue has too many due jobs, or its oldest due job has waited too long | 1000 jobs / 300 s | warning, critical at 2x |
| `:stalled` | a queue has overdue jobs and nothing in it was attempted recently (queue not running, paused, or leadership/notifier broken; also a queue whose every slot is busy with long-running jobs) | latency 300 s + no attempt in 60 s | always critical |
| `:retry_storm` | one worker has many jobs that failed within the window and are awaiting retry, or were retried within the window (completed retries only with `include_completed: true`) | 20 jobs / 300 s | warning, critical at 2x |
| `:discarded` | discarded-job spike for a worker (silent failures) | 5 / 3600 s | warning, critical at 2x |
| `:cancelled` | cancelled-job spike for a worker | 10 / 3600 s | warning, critical at 2x |
| `:cron_missing` | an expected (usually cron) worker has had no job inserted for too long | off until you list workers | always critical |

"Due" means `available`, or `scheduled`/`retryable` whose `scheduled_at` has passed. Job `args`,
`meta` and `errors` are never read. Nothing is sent anywhere; you decide where the report goes.

## Safety

* Only `SELECT`s on `oban_jobs` (audited by a test on every engine). On Postgres each
  check runs in a transaction marked read-only, with `statement_timeout` (5 s),
  `lock_timeout` (1 s) and a per-check budget (30 s), and the transaction is always rolled
  back. On MySQL `max_execution_time` is set for the duration of the check.
* All queries use Oban's standard indexes except the opt-in `:cron_missing` (a sequential
  scan). On a 10M-row table a full run takes about 2 s.
* `mix queue_keeper.check` and `QueueKeeperCheck.Release` start only your repo, never your
  application or Oban.
* Database errors never raise. A check that cannot complete is reported, and the exit
  code is 3.
* Run it with a SELECT-only database user.

See [docs/SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md) for the exact SQL, required
privileges, measurements and findings, and [SECURITY.md](SECURITY.md) to report a
vulnerability.

Status: v0.2.1, early. The API may change before 1.0.

> **Pruner caveat (read this first).** Five checks count rows in final states: `:stalled`
> (recent `attempted_at`), `:retry_storm` (with `include_completed: true`),
> `:discarded`, `:cancelled` and `:cron_missing`. If you run Oban's Pruner, it deletes
> `completed`, `cancelled` and `discarded` jobs older than `max_age`, **default 60 seconds**.
> With that default, the 3600 s spike windows only ever see the last minute, and
> `:cron_missing` reports any worker whose last run was pruned. Set the Pruner's `max_age`
> to at least your largest window (for `:cron_missing`, longer than your longest expected
> gap), e.g. `pruner: [max_age: {1, :day}]`, or shrink the check windows to fit.
> The Pruner is only active when configured (`pruner:` key or the `Oban.Pruner` plugin).

## Engine support

The same unit suite runs against each engine (see [Development and tests](#development-and-tests)).

| Oban engine | Database | Status |
|---|---|---|
| `Oban.Engines.Basic` | PostgreSQL | Tested: PostgreSQL 17.11, Oban 2.24.2 |
| `Oban.Engines.Lite` | SQLite3 | Tested: SQLite via `ecto_sqlite3` 0.26.0 / `exqlite` 0.43.0, Oban 2.24.2 |
| `Oban.Engines.Dolphin` | MySQL 8.4+ | Tested: MySQL 8.4.9 LTS (official generic Linux tarball) via `myxql` 0.9.0, Oban 2.24.2. MariaDB is not supported by Oban and not tested |
| `Oban.Pro.Engine` (formerly `Oban.Pro.Engines.Smart`) | PostgreSQL | **Not tested.** Likely compatible, unverified: Oban Pro requires a paid license, which this project does not have |

Oban Pro: from Pro's public documentation, the Pro engine keeps jobs in the same `oban_jobs`
table with the same states, so the queries should run, but some Pro features can make checks
report false results (rate-limited or globally limited queues look backed up or stalled; Pro's
`DynamicPruner`/`Oban.Pro.Pruner` keeps only 1,000 finished jobs by default; archived or
partitioned tables change what is visible). Read
[docs/OBAN_PRO_COMPATIBILITY.md](docs/OBAN_PRO_COMPATIBILITY.md) before relying on it with Pro.

Notes on SQLite: there are no schemas, so no prefix is passed (the Postgres default is
`"public"`). Timestamps are ISO-8601 text; Oban's column defaults write whole seconds
while Ecto writes microseconds, so comparisons are exact only to the second, which
matches the whole-second resolution of every check anyway.

Notes on MySQL: no library code changes were needed; every query is plain Ecto and
MyXQL compiles it to MySQL SQL (e.g. `CAST(min(scheduled_at) AS datetime(6))`, `?`
parameters, no `RETURNING`, no JSON functions, no interval arithmetic: windows are computed
in Elixir and passed as parameters). No prefix is passed by default; on MySQL a `:prefix`
means a *database* name, not a schema. Oban stores timestamps as `DATETIME(6)` in UTC, so
the server/session `time_zone` does not matter (verified with the server in UTC-5).
`state` is an `ENUM` column on MySQL; string comparisons work as on the other engines.

## Installation

Requires Elixir 1.15+, Oban 2.18+, `ecto_sql` 3.10+.

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:queue_keeper_check, "~> 0.2.1"}
  ]
end
```

Hex packages are checksummed in `mix.lock`. Or straight from GitHub, pinned to the release
tag (`tag: "v0.2.1"`); git tags can be moved, so for an immutable git pin use
`ref: "<commit sha>"`.

Your app already brings its own database adapter (`postgrex`, `ecto_sqlite3` or `myxql`).

## Usage

```elixir
report = QueueKeeperCheck.run(MyApp.Repo,
  hanging: [default_budget: 120, budgets: %{"MyApp.VideoWorker" => 1800}],
  backlog: [max_depth: 5_000, max_latency: 60]
)

report.status          #=> :ok | :warning | :critical
report.findings        #=> [%QueueKeeperCheck.Finding{check: :backlog, queue: "mailers", ...}]
IO.puts(QueueKeeperCheck.format(report))
```

Example output (default thresholds):

```
WARNING: 1 Oban queue problem(s) at 2026-10-22T05:09:00.881572Z
- [warning] discarded queue=default worker=MyApp.Workers.Sync: 7 MyApp.Workers.Sync job(s) exhausted their attempts or were discarded in the last 3600s (limit 5). These fail silently unless something alerts on them. sample_ids=[5, 6, 7, 8, 9, 10, 11]
```

Run it every minute from an Oban cron job in a dedicated `health` queue and post to Slack:

```elixir
defmodule MyApp.QueueHealth do
  use Oban.Worker, queue: :health

  @impl true
  def perform(_job) do
    report = QueueKeeperCheck.run(MyApp.Repo)
    if report.status != :ok, do: Req.post!(webhook_url(), json: QueueKeeperCheck.slack_payload(report))
    :ok
  end
end
```

A check running *inside* Oban can't tell you Oban itself is down; see the next section.

From the shell:

```
mix queue_keeper.check --repo MyApp.Repo [--prefix public] [--json] [--statement-timeout MS] [--lock-timeout MS]
```

It compiles the project and loads its config, then starts only the repo (pool of 1);
your application and Oban are not started.

### Exit codes

`mix queue_keeper.check` and `QueueKeeperCheck.Release.main/2` exit with:

| Code | Status | Meaning |
|---|---|---|
| 0 | `:ok` | no findings |
| 1 | `:warning` | at least one finding, none critical |
| 2 | `:critical` | at least one critical finding |
| 3 | `:error` | a check could not complete (database unreachable, timeout, missing table or column) or the arguments were invalid; no finding is critical |

Options: each check name takes a keyword list of thresholds (see `QueueKeeperCheck.Config`),
plus `:prefix` (schema; default `"public"` on Postgres, none on SQLite/MySQL; a plain
identifier), `:now` (evaluation time), `:only` (subset of checks) and the safety limits
`:statement_timeout`, `:lock_timeout`, `:check_timeout` (ms) and `:read_only`. Unknown or
invalid options raise `ArgumentError`. Failed checks are listed in `report.errors`.

### Missing cron insertions

List the workers you expect to see and the longest gap you tolerate (seconds). Pad the
gap: an hourly job checked every minute might use 3_900.

```elixir
QueueKeeperCheck.run(MyApp.Repo,
  cron_missing: [expected: %{"MyApp.HourlySync" => 3_900, "MyApp.NightlyReport" => 90_000}]
)
```

It looks at the newest row for each worker in any state, so it needs the Pruner to keep
rows longer than the gap (see the caveat above).

## When Oban itself is down

If Oban isn't running (crash loop, bad config, broken leadership, a deploy that never
started queues), a health worker *inside* Oban never runs, so it never alerts. Two
layers cover this:

1. **Run the check outside Oban, from system cron.** `QueueKeeperCheck.Release` starts only
   your repo, not your application, so it works when Oban is dead. In a release:

   ```
   # crontab: every 5 minutes
   */5 * * * * /app/bin/my_app eval 'QueueKeeperCheck.Release.main(MyApp.Repo, otp_app: :my_app)' >> /var/log/queue_check.log 2>&1
   ```

   It exits 0/1/2/3 (see [Exit codes](#exit-codes)). With Oban down, due jobs age and nothing
   is attempted, so `:stalled` fires; with `:cron_missing` configured, the missing cron worker
   fires too. (The test suite covers both conditions on every engine, and
   `dev/verify_host_app.sh` checks that `Release` runs without starting the app or Oban.)

2. **Tell someone outside your infrastructure that the check ran.** Cron can die too
   (host gone, crontab lost). Report every run to a dead-man's-switch service; if the pings
   stop, *it* alerts you. For example, Healthchecks.io accepts the exit status in the URL
   (`https://hc-ping.com/<uuid>/<exit-status>`, 0 = success, anything else = failure,
   see https://healthchecks.io/docs/http_api/):

   ```
   */5 * * * * /app/bin/my_app eval '...Release.main(MyApp.Repo, otp_app: :my_app)'; curl -fsS -m 10 --retry 3 "https://hc-ping.com/$HC_UUID/$?" >/dev/null
   ```

   This is the library's only network-shaped advice; the library itself never calls out.

## Piloting safely

Don't wire it straight to your pager. Roll it out in stages:

1. **Report-only first.** Run it on its normal schedule but only log the report (e.g.
   `Logger.info(QueueKeeperCheck.format(report))`, or append the `--json` output to a file).
   No paging, no Slack.
2. **Measure for a week or two.** For every finding, record:
   * was it a **false positive** (nothing was actually wrong)?
   * was it a **useful detection** (a real problem, ideally one you didn't already know about)?
   * **what action an engineer took** because of it (none, investigated, fixed something)?
   * the **query cost**: how long each run takes (time the call, or watch
     `pg_stat_statements` / your database's slow-query log) and whether it shows up in your
     database metrics at all.
3. **Tune thresholds** from what you measured: per-worker `hanging` budgets for slow workers,
   `backlog` depth/latency that matches your traffic, `min_*` counts and windows for the spike
   checks. Turn off (`only:`) checks that don't earn their keep.
4. **Then route to alerts**, starting with `:critical` only, and keep the report-only log
   for comparison.

**History-based checks depend on retention.** `:stalled` (recent attempts), `:retry_storm`
with `include_completed: true`, `:discarded`, `:cancelled` and `:cron_missing` read jobs in
final states, so they only see as far back as your Pruner keeps rows (see the Pruner
caveat near the top). Prefer shrinking the check windows to fit your
existing pruning (e.g. `discarded: [window: 60]` with the default 60 s `max_age`) over
raising retention just for the checker: longer retention means a bigger `oban_jobs` table for
Oban itself, which is a cost you should take on for your own reasons, not for this library.

## Caveats
- Pruner window: see the caveat at the top. In short, `max_age` must cover your largest window,
  or the windows must shrink to fit `max_age`.
- `:orphaned` measures execution age only (`executing` with `attempted_at` older than the
  limit). It cannot tell a job orphaned by a node crash from one that is legitimately still
  running; set the limit above your longest legitimate runtime. It overlaps with Oban's
  Lifeline plugin: if Lifeline is on, orphans are rescued and this check mostly sees them only
  before the rescue runs.
- `:stalled` also fires when every slot of a queue is held by long-running jobs and due work
  is waiting, because nothing was *attempted* in the activity window. `:hanging`/`:orphaned`
  findings for the same queue point to that case.
- `:retry_storm` counts a `retryable` job by its last failed attempt (`attempted_at`), so a
  job failing once and then waiting out a long backoff drops out of the window. Database and
  application clocks skewed by more than a job's backoff can make a just-failed job miss the
  window.
- Ages are whole seconds.

## Development and tests

Needs PostgreSQL on localhost (user/password `postgres`, database `queue_keeper_check_test`
is created and dropped by the test run); SQLite needs nothing (files under `tmp/`).
MySQL is opt-in with `QK_MYSQL=1` and needs a MySQL 8.4+ server (defaults: `127.0.0.1:3307`,
user `root`, no password; override with `QK_MYSQL_HOST`, `QK_MYSQL_PORT`, `QK_MYSQL_USER`,
`QK_MYSQL_PASSWORD`). On x86_64 Linux, `dev/mysql84.sh install && dev/mysql84.sh start` sets up
exactly that from the official MySQL tarball under `./.mysql`, no Docker or root server needed.
Each suite runs once per engine.

```
mix deps.get
mix test                 # Postgres + SQLite
QK_MYSQL=1 mix test      # + MySQL
mix format --check-formatted
```

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Titanium Monkey Labs.
Website: <https://queuekeeper.dev>. Contact: hello@queuekeeper.dev.
