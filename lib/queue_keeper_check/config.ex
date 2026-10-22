defmodule QueueKeeperCheck.Config do
  @moduledoc """
  Thresholds. All durations are in seconds. Pass overrides as keyword lists:

      QueueKeeperCheck.run(MyApp.Repo, backlog: [max_depth: 5_000], hanging: [default_budget: 120])

  Defaults:

  | check | option | default | meaning |
  |---|---|---|---|
  | `:orphaned` | `after` | 3600 | executing longer than this = node probably died (matches Oban Lifeline's default `rescue_after` of 60 min) |
  | `:hanging` | `default_budget` | 300 | executing longer than the worker's budget |
  | `:hanging` | `budgets` | `%{}` | per-worker budgets, e.g. `%{"MyApp.VideoWorker" => 1800}` |
  | `:backlog` | `max_depth` | 1000 | due jobs (available, or scheduled/retryable whose time has passed) per queue |
  | `:backlog` | `max_latency` | 300 | age of the oldest due job per queue |
  | `:stalled` | `window` | 60 | due jobs older than `backlog.max_latency` and no job attempted in this queue within the window |
  | `:retry_storm` | `window` | 300 | look-back window |
  | `:retry_storm` | `min_retries` | 20 | retryable jobs, or jobs on attempt >= 2 attempted in the window, per worker |
  | `:discarded` | `window` / `max` | 3600 / 5 | jobs discarded in the window, per worker |
  | `:cancelled` | `window` / `max` | 3600 / 10 | jobs cancelled in the window, per worker |
  | `:cron_missing` | `expected` | `%{}` (off) | worker => max seconds between insertions, e.g. `%{"MyApp.Nightly" => 90_000}` |

  A finding is `:critical` when the value is at least twice its threshold; `:orphaned`,
  `:stalled` and `:cron_missing` findings are always `:critical`.
  """

  @defaults [
    orphaned: [after: 3600],
    hanging: [default_budget: 300, budgets: %{}],
    backlog: [max_depth: 1000, max_latency: 300],
    stalled: [window: 60],
    retry_storm: [window: 300, min_retries: 20],
    discarded: [window: 3600, max: 5],
    cancelled: [window: 3600, max: 10],
    cron_missing: [expected: %{}]
  ]

  @doc "Merge user options over the defaults."
  def build(opts) do
    Enum.map(@defaults, fn {check, defaults} ->
      {check, Keyword.merge(defaults, Keyword.get(opts, check, []))}
    end)
  end

  def defaults, do: @defaults
end
