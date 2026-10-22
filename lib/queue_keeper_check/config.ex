defmodule QueueKeeperCheck.Config do
  @moduledoc """
  Thresholds and safety limits. All check durations are in seconds. Pass overrides as
  keyword lists:

      QueueKeeperCheck.run(MyApp.Repo, backlog: [max_depth: 5_000], hanging: [default_budget: 120])

  Check defaults:

  | check | option | default | meaning |
  |---|---|---|---|
  | `:orphaned` | `after` | 3600 | executing longer than this = node probably died (matches Oban Lifeline's default `rescue_after` of 60 min) |
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

  `:retry_storm` counts, per worker: jobs in `retryable` now, plus jobs `executing`,
  `discarded` or `cancelled` on attempt >= 2 that were attempted in the window (plus
  `completed` ones with `include_completed: true`).

  A finding is `:critical` when the value is at least twice its threshold; `:orphaned`,
  `:stalled` and `:cron_missing` findings are always `:critical`.

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
    cron_missing: [expected: %{}]
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

  defp validate!(_check, :include_completed, v) when is_boolean(v), do: :ok

  defp validate!(check, key, v) when key != :include_completed do
    unless is_integer(v) and v >= 0,
      do:
        raise(
          ArgumentError,
          "#{inspect(check)} #{inspect(key)} must be a non-negative integer, got: #{inspect(v)}"
        )
  end

  defp validate!(check, key, v),
    do:
      raise(
        ArgumentError,
        "#{inspect(check)} #{inspect(key)} must be a boolean, got: #{inspect(v)}"
      )
end
