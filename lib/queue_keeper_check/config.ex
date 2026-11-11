defmodule QueueKeeperCheck.Config do
  @moduledoc """
  Thresholds and safety limits. All check durations are in seconds. Pass overrides as
  keyword lists:

      QueueKeeperCheck.run(MyApp.Repo, backlog: [max_depth: 5_000], hanging: [default_budget: 120])

  Check defaults:

  | check | option | default | meaning |
  |---|---|---|---|
  | `:orphaned` | `after` | 3600 | executing longer than this, far beyond any expected runtime (matches Oban Lifeline's default `rescue_after` of 60 min). Measures execution age only: the job may be orphaned by a node crash, or may still be running |
  | `:hanging` | `default_budget` | 300 | executing longer than the worker's budget |
  | `:hanging` | `budgets` | `%{}` | per-worker budgets, e.g. `%{"MyApp.VideoWorker" => 1800}` |
  | `:backlog` | `max_depth` | 1000 | due jobs (available, or scheduled/retryable whose time has passed) per queue |
  | `:backlog` | `max_latency` | 300 | age of the oldest due job per queue |
  | `:stalled` | `window` | 60 | due jobs older than `backlog.max_latency` and no job attempted in this queue within the window |
  | `:stalled` | `lookback` | 3600 | completed jobs count as recent activity only if they were scheduled at most this many seconds before the queue's oldest due job (bounds the query; see `QueueKeeperCheck.Checks.stalled/4`) |
  | `:retry_storm` | `window` | 300 | look-back window |
  | `:retry_storm` | `min_retries` | 20 | retrying/retried jobs per worker (see below) |
  | `:retry_storm` | `include_completed` | `false` | also count *completed* jobs on attempt >= 2 attempted in the window. Costs a full scan of `oban_jobs` on large tables (no index on `attempted_at`), so it is off by default |
  | `:discarded` | `window` / `max` | 3600 / 5 | jobs discarded in the window, per worker |
  | `:cancelled` | `window` / `max` | 3600 / 10 | jobs cancelled in the window, per worker |
  | `:cron_missing` | `expected` | `%{}` (off) | worker => max seconds between insertions, e.g. `%{"MyApp.Nightly" => 90_000}` |
  | `:dead_workers` | `window_days` | `nil` (off) | any positive integer number of days since a worker was last *inserted* (enqueued). 7, 14 and 30 are common examples; if you set `known` or `discover: true` without `window_days`, the window is **7** (was 14 in 0.3.0). There is no fixed set of allowed values. Inactivity here is a strict `age > window` (exactly N days does not fire) |
  | `:dead_workers` | `ignore` | `[]` | worker names to skip (rare/seasonal jobs, or ones you have reviewed) |
  | `:dead_workers` | `known` | `[]` | extra worker names to check, including those with no rows at all (workers that never ran, or were fully pruned) |
  | `:dead_workers` | `overrides` | `%{}` | per-worker window in days, e.g. `%{"MyApp.YearlyClose" => 400}` |
  | `:dead_workers` | `discover` | `false` | also check `Oban.Worker` modules in loaded non-OTP applications (needs the host app started; `mix queue_keeper.check` and `Release` do not start it) |
  | `:dead_workers` | `report_short_history` | `false` | if the window is longer than the ledger's recording age (or, without a ledger, finished-job history), emit a warning instead of staying silent |
  | `:dead_workers` | `use_ledger` | `true` | when the opt-in ledger tables exist and recording has started, read last-seen times from them (cheap) instead of scanning `oban_jobs`. The check itself still only SELECTs; writing to the ledger is a separate, explicit `QueueKeeperCheck.Ledger.attach/1` |
  | `:persisted_jobs` | `workers` | `[]` | deployed worker name strings (the trusted inventory). Compared as strings; never turned into atoms |
  | `:persisted_jobs` | `previous_workers` | `[]` | extra worker names still considered deployed (rolling rename / rollout). Unioned with `workers` |
  | `:persisted_jobs` | `queues` | `[]` | effective queue name strings for this Oban prefix |
  | `:persisted_jobs` | `paused_queues` | `[]` | operator-supplied list of queues known to be paused. The check does not read pause state from the cluster |
  | `:persisted_jobs` | `dynamic_queues` | `:unknown` | `:unknown` (default): queues not in `queues` are `:insufficient_evidence`, never unconfigured. `:enumerated`: the `queues` list is complete, so others are `:unconfigured_queue` |
  | `:persisted_jobs` | `consumers` | `:unknown` | `:unknown` (default): never emit `:no_active_consumer` (one node cannot prove a deployment-wide gap). A list of queue name strings is a cluster-wide snapshot you supply; queues with leftover jobs not in that list may be `:no_active_consumer` |
  | `:persisted_jobs` | `discover` | `false` | union `Oban.Worker` modules in loaded non-OTP apps into the worker inventory (needs the host app started; `mix queue_keeper.check` and `Release` do not start it). If `discover` is the only worker source and it finds nothing, the check reports `:insufficient_evidence` instead of treating every job worker as missing |
  | `:persisted_jobs` | `ignore_workers` / `ignore_queues` | `[]` | names to skip |
  | `:dead_worker_candidates` | `window_days` | `nil` (off) | any positive integer; **7** if you only set `known` or `discover: true`. Combined check uses inclusive `age >= window` ("at least N days") |
  | `:dead_worker_candidates` | `ignore` / `known` / `overrides` / `discover` / `use_ledger` | same as `:dead_workers` | same meanings. Always reports insufficient history as `:unknown` (does not stay silent) |
  | `:dead_worker_candidates` | `scan` | `[]` | options forwarded to `QueueKeeperCheck.DeadCode.scan_report/1` (`:apps`, `:callers`, `:cron`, `:beam_roots`, …) |

  `:retry_storm` counts, per worker, within the window:

    * `retryable` jobs whose last (failed) attempt started in the window (`attempted_at`;
      the query also bounds `scheduled_at`, which Oban sets after the attempt, so it can
      use the composite index),
    * `executing` jobs on attempt >= 2 attempted in the window (`attempted_at`),
    * `discarded` / `cancelled` jobs on attempt >= 2 discarded / cancelled in the window
      (`discarded_at` / `cancelled_at`),
    * with `include_completed: true`, `completed` jobs on attempt >= 2 attempted in the
      window (`attempted_at`).

  A job that failed before the window and is still waiting out a long backoff is not
  counted. (Up to v0.2.0 every `retryable` job counted, whatever the window.)

  A finding is `:critical` when the value is at least twice its threshold; `:orphaned`,
  `:stalled` and `:cron_missing` findings are always `:critical`. `:dead_workers`
  findings are always `:warning` (they are a hint about possible dead code, not a
  production outage).

  `:dead_workers` is off until you set `window_days` (any positive integer), or you
  set a non-empty `known` list or `discover: true`. If you omit `window_days`, the
  implicit window is 7 days (changed from 14 in 0.3.0; set `window_days: 14` to
  keep the old implicit window). It uses last enqueue, not last execution: a
  worker that is still being enqueued is not unused code. When the
  opt-in last-seen ledger is present (see `QueueKeeperCheck.Ledger`), activity
  comes from that tiny table and the check stays silent until the ledger itself
  has been recording for the window; you do not need to raise the Pruner
  `max_age`. Without a ledger it falls back to `max(inserted_at)` on
  `oban_jobs`, and if the oldest finished job is newer than a worker's window
  that worker is not flagged. Workers listed in `cron_missing.expected` are
  skipped so the two checks do not double-report.

  `:persisted_jobs` is off until you pass a worker inventory (`workers`,
  `previous_workers`, or `discover: true`), a queue inventory (`queues` or
  `paused_queues`), or a `consumers` snapshot. It is report-only: bounded
  `SELECT`s of nonterminal rows (`available`, `scheduled` including future,
  `retryable`, `executing`, and core `suspended`). One `run/2` covers one
  prefix; run once per Oban instance. Worker and queue names from the
  database stay strings. Oban Pro-specific states or archive tables are
  not queried; Pro support beyond core `suspended` is untested and unverified.

  `:dead_worker_candidates` is off until you set `window_days`, a non-empty
  `known` list, or `discover: true`. It combines enqueue inactivity with the
  static scan and leftover-job evidence. A high-confidence finding requires
  both no enqueue for at least the window (inclusive; default 7 days) with
  sufficient history, and no code or cron reference, with no pending or
  future-scheduled jobs and a complete static scan. It never claims a worker
  is definitely dead. Insufficient history is reported as `:unknown`.

  Safety options (top level, not per check):

  | option | default | meaning |
  |---|---|---|
  | `:statement_timeout` | 5000 | ms. Per statement server-side limit (Postgres `statement_timeout`, MySQL `max_execution_time`); also the basis of the client-side timeout on every engine |
  | `:lock_timeout` | 1000 | ms. Postgres `lock_timeout`: give up rather than queue behind a lock (e.g. a migration) |
  | `:check_timeout` | 30000 | ms. Client-side budget for one whole check (Postgres transaction / MySQL checkout holding one connection); the connection is dropped if exceeded |
  | `:read_only` | `true` | Postgres: run each check in a transaction marked `transaction_read_only`, so the server rejects any write |
  | `:prefix` | `"public"` (Postgres), none elsewhere | schema of `oban_jobs` (a database name on MySQL). Must be a plain identifier, `[A-Za-z_][A-Za-z0-9_]{0,62}`, or `false` for no prefix (use the connection's `search_path`) |

  Invalid or unknown options raise `ArgumentError` before any query runs.
  """

  @defaults [
    orphaned: [after: 3600],
    hanging: [default_budget: 300, budgets: %{}],
    backlog: [max_depth: 1000, max_latency: 300],
    stalled: [window: 60, lookback: 3600],
    retry_storm: [window: 300, min_retries: 20, include_completed: false],
    discarded: [window: 3600, max: 5],
    cancelled: [window: 3600, max: 10],
    cron_missing: [expected: %{}],
    dead_workers: [
      window_days: nil,
      ignore: [],
      known: [],
      overrides: %{},
      discover: false,
      report_short_history: false,
      use_ledger: true
    ],
    persisted_jobs: [
      workers: [],
      previous_workers: [],
      queues: [],
      paused_queues: [],
      dynamic_queues: :unknown,
      consumers: :unknown,
      discover: false,
      ignore_workers: [],
      ignore_queues: []
    ],
    dead_worker_candidates: [
      window_days: nil,
      ignore: [],
      known: [],
      overrides: %{},
      discover: false,
      use_ledger: true,
      scan: []
    ]
  ]

  @guard_defaults [
    statement_timeout: 5_000,
    lock_timeout: 1_000,
    check_timeout: 30_000,
    read_only: true
  ]

  @top_level [:prefix, :now, :only] ++ Keyword.keys(@guard_defaults)

  @prefix ~r/\A[A-Za-z_][A-Za-z0-9_]{0,62}\z/

  @doc "Merge user options over the defaults, validating every value. Raises `ArgumentError`."
  def build(opts) when is_list(opts) do
    validate_keys!(opts)

    Enum.map(@defaults, fn {check, defaults} ->
      given = Keyword.get(opts, check, [])

      unless Keyword.keyword?(given),
        do: raise(ArgumentError, "#{inspect(check)} options must be a keyword list")

      for {key, value} <- given do
        unless Keyword.has_key?(defaults, key),
          do:
            raise(
              ArgumentError,
              "unknown option #{inspect(key)} for #{inspect(check)}; " <>
                "expected one of #{inspect(Keyword.keys(defaults))}"
            )

        validate!(check, key, value)
      end

      {check, Keyword.merge(defaults, given)}
    end)
  end

  @doc "Safety options (`:statement_timeout`, `:lock_timeout`, `:read_only`) merged over defaults."
  def guard(opts) do
    Keyword.merge(@guard_defaults, Keyword.take(opts, Keyword.keys(@guard_defaults)))
  end

  def defaults, do: @defaults
  def guard_defaults, do: @guard_defaults

  @doc """
  Validate an Oban prefix. Ecto already quotes it as an identifier (and rejects quote
  characters); this is a stricter allow-list so a prefix can only ever be a plain name.
  """
  def valid_prefix?(prefix), do: is_binary(prefix) and Regex.match?(@prefix, prefix)

  defp validate_keys!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")
    known = @top_level ++ Keyword.keys(@defaults)

    for {key, value} <- opts do
      unless key in known,
        do:
          raise(
            ArgumentError,
            "unknown option #{inspect(key)}; expected one of #{inspect(known)}"
          )

      validate_top!(key, value)
    end
  end

  defp validate_top!(:prefix, p) when p in [nil, false], do: :ok

  defp validate_top!(:prefix, p) do
    unless valid_prefix?(p),
      do:
        raise(
          ArgumentError,
          ":prefix must be a plain identifier matching #{inspect(Regex.source(@prefix))}, got: #{inspect(p)}"
        )
  end

  defp validate_top!(:now, %DateTime{}), do: :ok

  defp validate_top!(:now, v),
    do: raise(ArgumentError, ":now must be a DateTime, got: #{inspect(v)}")

  defp validate_top!(:only, list) when is_list(list) do
    case list -- Keyword.keys(@defaults) do
      [] -> :ok
      bad -> raise ArgumentError, "unknown check(s) in :only: #{inspect(bad)}"
    end
  end

  defp validate_top!(:only, v),
    do: raise(ArgumentError, ":only must be a list, got: #{inspect(v)}")

  defp validate_top!(key, v) when key in [:statement_timeout, :lock_timeout, :check_timeout] do
    unless is_integer(v) and v > 0 and v <= 3_600_000,
      do:
        raise(
          ArgumentError,
          "#{inspect(key)} must be an integer 1..3_600_000 (ms), got: #{inspect(v)}"
        )
  end

  defp validate_top!(:read_only, v) when is_boolean(v), do: :ok

  defp validate_top!(:read_only, v),
    do: raise(ArgumentError, ":read_only must be a boolean, got: #{inspect(v)}")

  defp validate_top!(_check, _v), do: :ok

  defp validate!(_check, key, map) when key in [:budgets, :expected] do
    valid =
      is_map(map) and
        Enum.all?(map, fn {w, s} -> is_binary(w) and is_integer(s) and s >= 0 end)

    unless valid,
      do:
        raise(
          ArgumentError,
          "#{inspect(key)} must be a map of worker name (string) => non-negative integer seconds, got: #{inspect(map)}"
        )
  end

  defp validate!(check, :window_days, nil)
       when check in [:dead_workers, :dead_worker_candidates],
       do: :ok

  defp validate!(check, :window_days, v)
       when check in [:dead_workers, :dead_worker_candidates] do
    unless is_integer(v) and v >= 1,
      do:
        raise(
          ArgumentError,
          "#{check} :window_days must be a positive integer (days), got: #{inspect(v)}"
        )
  end

  defp validate!(_check, key, list) when key in [:ignore, :known] do
    unless is_list(list) and Enum.all?(list, &is_binary/1),
      do:
        raise(
          ArgumentError,
          "#{inspect(key)} must be a list of worker name strings, got: #{inspect(list)}"
        )
  end

  defp validate!(_check, :overrides, map) do
    valid =
      is_map(map) and
        Enum.all?(map, fn {w, d} -> is_binary(w) and is_integer(d) and d >= 1 end)

    unless valid,
      do:
        raise(
          ArgumentError,
          "overrides must be a map of worker name (string) => positive integer days, got: #{inspect(map)}"
        )
  end

  defp validate!(:dead_worker_candidates, :scan, v) do
    unless Keyword.keyword?(v),
      do:
        raise(
          ArgumentError,
          "dead_worker_candidates :scan must be a keyword list, got: #{inspect(v)}"
        )
  end

  defp validate!(_check, key, v)
       when key in [:include_completed, :discover, :report_short_history, :use_ledger] do
    unless is_boolean(v),
      do: raise(ArgumentError, "#{inspect(key)} must be a boolean, got: #{inspect(v)}")
  end

  defp validate!(_check, key, list)
       when key in [
              :workers,
              :previous_workers,
              :queues,
              :paused_queues,
              :ignore_workers,
              :ignore_queues
            ] do
    unless is_list(list) and Enum.all?(list, &is_binary/1),
      do:
        raise(
          ArgumentError,
          "#{inspect(key)} must be a list of name strings, got: #{inspect(list)}"
        )
  end

  defp validate!(:persisted_jobs, :dynamic_queues, v) when v in [:unknown, :enumerated], do: :ok

  defp validate!(:persisted_jobs, :dynamic_queues, v),
    do:
      raise(
        ArgumentError,
        "persisted_jobs :dynamic_queues must be :unknown or :enumerated, got: #{inspect(v)}"
      )

  defp validate!(:persisted_jobs, :consumers, :unknown), do: :ok

  defp validate!(:persisted_jobs, :consumers, list) do
    unless is_list(list) and Enum.all?(list, &is_binary/1),
      do:
        raise(
          ArgumentError,
          "persisted_jobs :consumers must be :unknown or a list of queue name strings, got: #{inspect(list)}"
        )
  end

  defp validate!(check, key, v)
       when key not in [:include_completed, :discover, :report_short_history, :use_ledger] do
    unless is_integer(v) and v >= 0,
      do:
        raise(
          ArgumentError,
          "#{inspect(check)} #{inspect(key)} must be a non-negative integer, got: #{inspect(v)}"
        )
  end
end
