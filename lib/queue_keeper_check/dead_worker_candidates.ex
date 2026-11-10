defmodule QueueKeeperCheck.DeadWorkerCandidates do
  @moduledoc """
  Combined, report-only classification of dead-worker *review candidates*.

  This is a different check from `:dead_workers` (enqueue inactivity) and from
  `QueueKeeperCheck.DeadCode` (static reachability). A **high-confidence**
  candidate is a worker that has **both**:

  1. no observed enqueue for at least `window_days` (default **7**), with
     observation history long enough to support that claim, and
  2. no references in compiled application code or crontab from Application env.

  It never deletes code, jobs or queues, and it never claims a worker is
  definitely dead. Findings always include the evidence and a confidence
  (`Finding.reason`).

  ## Window and boundary

  `window_days` is any positive integer (the same rule as `:dead_workers`).
  When you enable the check without setting `window_days` (for example you
  only set `known` or `discover: true`), the window is **7 days**.

  Inactivity is `age >= window_days * 86_400` whole seconds. Age is
  `DateTime.diff(now, last_inserted_at, :second)` against the `now` passed to
  `QueueKeeperCheck.run/2` (default `DateTime.utc_now/0`). A last insert
  *exactly* seven days before `now` therefore counts as "at least seven days."
  The standalone `:dead_workers` check still uses a strict `age > window`
  comparison (so exactly N days does not fire there, and N days plus one
  second does). That difference is intentional and documented.

  ## Confidence (`Finding.reason`)

  * `:high_confidence` — both signals agree, history covers the window, the
    static scan is complete, and no nonterminal (including future-scheduled)
    jobs remain. Still not proof: dynamic dispatch can hide callers, and a
    worker may legitimately run less often than the window.
  * `:referenced` — enqueue inactivity holds, but the worker is referenced in
    code or cron, so it is **not** a high-confidence dead candidate.
  * `:pending_jobs` — inactivity plus no static/cron reference, but leftover
    nonterminal or future-scheduled jobs remain. An old `inserted_at` is not
    proof those jobs are dead.
  * `:incomplete_analysis` — both signals lean that way, but BEAM debug info
    or compile paths were incomplete, so a hidden caller is possible.
  * `:insufficient_history` — a new environment, short ledger, or aggressive
    pruning means history is shorter than the window. That is **unknown**, not
    proof of inactivity.
  * `:unknown` — pending-job evidence could not be read (query error).

  Workers that are still being enqueued, or that are referenced and not
  inactive, are omitted.
  """

  @seconds_per_day 86_400
  @default_window_days 7

  @doc "Default window in days when the check is on and `window_days` is omitted."
  def default_window_days, do: @default_window_days

  @doc "Window length in whole seconds."
  def window_seconds(days) when is_integer(days) and days >= 1, do: days * @seconds_per_day

  @doc """
  True when there is no last insert, or the last insert is at least
  `window_secs` before `now` (inclusive).
  """
  def inactive?(nil, _now, _window_secs), do: true

  def inactive?(at, now, window_secs) when is_integer(window_secs) do
    age(at, now) >= window_secs
  end

  @doc """
  Classify one worker. Returns `{:reason, message}` or `:omit`.

  `attrs` must include: `:worker`, `:history_secs`, `:window_secs`,
  `:window_days`, `:now`, `:last_inserted_at`, `:pending_status` (`:ok` or
  `:error`), `:pending_count`, `:next_scheduled_at`, `:static`
  (`:referenced`, `:unreferenced`, or `:not_in_scan`), `:static_reason`
  (`:callers`, `:cron`, `:no_call_sites`, or `nil`), `:static_files`
  (list of paths), and `:scan_complete?`.
  """
  def classify(attrs) when is_map(attrs) do
    history_ok? = attrs.history_secs >= attrs.window_secs
    inactive? = inactive?(attrs.last_inserted_at, attrs.now, attrs.window_secs)
    referenced? = attrs.static == :referenced
    no_ref? = attrs.static in [:unreferenced, :not_in_scan]
    pending? = attrs.pending_status == :ok and attrs.pending_count > 0
    pending_unknown? = attrs.pending_status == :error

    cond do
      inactive? and not history_ok? ->
        {:insufficient_history, insufficient_history_message(attrs)}

      referenced? and inactive? ->
        {:referenced, referenced_message(attrs)}

      no_ref? and inactive? and pending? ->
        {:pending_jobs, pending_message(attrs)}

      no_ref? and inactive? and pending_unknown? ->
        {:unknown, pending_unknown_message(attrs)}

      no_ref? and inactive? and not attrs.scan_complete? ->
        {:incomplete_analysis, incomplete_message(attrs)}

      no_ref? and inactive? and attrs.scan_complete? ->
        {:high_confidence, high_message(attrs)}

      true ->
        :omit
    end
  end

  @doc false
  def age(nil, _now), do: nil
  def age(%NaiveDateTime{} = t, now), do: age(DateTime.from_naive!(t, "Etc/UTC"), now)
  def age(%DateTime{} = t, now), do: max(DateTime.diff(now, t, :second), 0)

  defp evidence(attrs) do
    insert =
      case {attrs.last_inserted_at, age(attrs.last_inserted_at, attrs.now)} do
        {nil, _} ->
          "no observed enqueue (never inserted, or pruned from oban_jobs / not in the ledger)"

        {_, secs} ->
          "last enqueue (inserted_at) #{secs}s ago"
      end

    static =
      case attrs.static do
        :referenced ->
          files =
            case attrs.static_files do
              [] -> ""
              list -> " in #{Enum.join(list, ", ")}"
            end

          "referenced in " <>
            if(attrs.static_reason == :cron, do: "cron config", else: "application code#{files}")

        :unreferenced ->
          "no static callers and not in cron config from Application env"

        :not_in_scan ->
          "not found as a compiled Oban.Worker in the scanned applications (no static callers or cron entries visible)"
      end

    pending =
      cond do
        attrs.pending_status == :error ->
          "could not query leftover nonterminal jobs"

        attrs.pending_count > 0 ->
          next =
            case attrs.next_scheduled_at do
              nil ->
                ""

              at ->
                rel = DateTime.diff(at, attrs.now)

                if rel > 0 do
                  "; next scheduled_at is #{rel}s from now"
                else
                  "; oldest pending scheduled_at is #{-rel}s ago"
                end
            end

          "#{attrs.pending_count} nonterminal job(s) remain (available, scheduled including future, retryable, executing, or suspended)#{next}"

        true ->
          "no nonterminal jobs remain"
      end

    "Evidence: #{insert}; observation history #{attrs.history_secs}s (window #{attrs.window_days} days / #{attrs.window_secs}s); #{static}; #{pending}."
  end

  defp caveat do
    " This is a review candidate, not proof the worker is dead. Dynamic dispatch, " <>
      "runtime-only cron, workers that run less often than the window, and retention " <>
      "limits can all produce false positives; do not delete code, jobs or queues on this finding alone."
  end

  defp insufficient_history_message(attrs) do
    "#{attrs.worker}: observation history (#{attrs.history_secs}s) is shorter than the " <>
      "#{attrs.window_days}-day window (#{attrs.window_secs}s). This is unknown, not proof of " <>
      "inactivity (new environment, short ledger, or aggressive pruning). " <>
      evidence(attrs) <> caveat()
  end

  defp referenced_message(attrs) do
    "#{attrs.worker} has had no observed enqueue for at least #{attrs.window_days} days, " <>
      "but it is still referenced in application code or cron, so it is not a " <>
      "high-confidence dead-worker candidate. " <> evidence(attrs) <> caveat()
  end

  defp pending_message(attrs) do
    "#{attrs.worker} has had no observed enqueue for at least #{attrs.window_days} days " <>
      "and no static or cron reference, but leftover pending or future-scheduled jobs " <>
      "remain. An old inserted_at is not proof those jobs are dead. " <>
      evidence(attrs) <> caveat()
  end

  defp pending_unknown_message(attrs) do
    "#{attrs.worker} looks inactive and unreferenced, but leftover nonterminal jobs " <>
      "could not be queried (unknown). " <> evidence(attrs) <> caveat()
  end

  defp incomplete_message(attrs) do
    "#{attrs.worker} has had no observed enqueue for at least #{attrs.window_days} days " <>
      "and no visible static or cron reference, but the static scan is incomplete " <>
      "(missing BEAM debug info or empty compile paths), so a hidden caller is possible. " <>
      evidence(attrs) <> caveat()
  end

  defp high_message(attrs) do
    "#{attrs.worker} has had no observed enqueue for at least #{attrs.window_days} days " <>
      "(history covers the window) and has no references in scanned application code or " <>
      "cron configuration. Confidence: high (both signals agree). " <>
      evidence(attrs) <> caveat()
  end
end
