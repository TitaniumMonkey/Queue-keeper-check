defmodule QueueKeeperCheck.Checks do
  @moduledoc """
  The individual checks. Each takes `(repo, config, now, query_opts)` and returns a list of
  `QueueKeeperCheck.Finding` structs. `QueueKeeperCheck.run/2` wraps each call in
  `QueueKeeperCheck.Guard`; call these directly only if you apply your own limits.

  Every query is a plain `SELECT`. Checks read only `id`, `state`, `queue`,
  `worker`, `attempt` and timestamp columns from `oban_jobs`. `args`, `meta`, `errors`, `tags` and
  `attempted_by` are never selected or filtered on. When the opt-in ledger is present,
  `:dead_workers` SELECTs from `queue_keeper_worker_sightings` and
  `queue_keeper_ledger_meta` instead of scanning `oban_jobs`. The opt-in
  `:persisted_jobs` and `:dead_worker_candidates` checks also SELECT nonterminal
  `oban_jobs` rows (state-prefixed).
  Each query is either an aggregate
  (one row per queue or worker) or capped with `LIMIT`, and each is shaped to use Oban's
  standard indexes (`state, queue, priority, scheduled_at, id`; `state, discarded_at`;
  `state, cancelled_at`; the primary key). See `docs/SECURITY_REVIEW.md` for the exact SQL
  and measured plans.
  """
  import Ecto.Query
  alias Oban.Job
  alias QueueKeeperCheck.Finding

  @sample 10
  @sample_queries 100

  # Nonterminal Oban states (core Job.unique_states(:incomplete), including
  # `:suspended` which exists in Oban >= 2.21 / migrations v14). Bounded by
  # the leading `state` column of Oban's standard indexes; not a full-table
  # GROUP BY the way the enqueue-activity fallback is.
  @incomplete_job_states ~w(available scheduled retryable executing suspended)

  # -- executing jobs: orphaned and hanging -----------------------------------------------
  # Aggregated in SQL so the result stays one row per (queue, worker), however many rows
  # are stuck in `executing`. `age >= after` <=> `attempted_at <= now - after`.
  #
  # :orphaned measures execution age only. The database does not record which node runs a
  # job or whether that node is alive, so a job past `after` may be orphaned (its node
  # crashed or was killed mid-job) or may simply still be running; the finding cannot
  # tell the two apart.

  def orphaned(repo, cfg, now, qopts) do
    limit = cfg[:orphaned][:after]
    cutoff = DateTime.add(now, -limit, :second)
    base = from(j in Job, where: j.state == "executing" and j.attempted_at <= ^cutoff)

    for {queue, worker, count, first} <- executing_groups(repo, base, qopts) do
      oldest = age(first, now)

      %Finding{
        check: :orphaned,
        severity: :critical,
        queue: queue,
        worker: worker,
        count: count,
        value: oldest,
        threshold: limit,
        message:
          "#{count} job(s) executing for up to #{oldest}s (limit #{limit}s), far beyond any expected runtime; possibly orphaned by a node crash or shutdown, or genuinely still running. This check measures execution age only; Oban's Lifeline plugin rescues orphaned jobs.",
        job_ids: sample_ids(repo, scoped(base, queue, worker), qopts)
      }
    end
  end

  # One aggregate per distinct budget: workers without an explicit budget share the default.
  # `age > budget` <=> `attempted_at <= now - (budget + 1)` (ages are whole seconds).
  def hanging(repo, cfg, now, qopts) do
    # When :orphaned is also running, exclude jobs at/past the orphan cutoff so
    # they are not reported twice. When :orphaned is disabled, hanging must still
    # report over-budget jobs regardless of how old they are.
    orphan_cutoff =
      if orphaned_check_enabled?() do
        DateTime.add(now, -cfg[:orphaned][:after], :second)
      end

    budgets = cfg[:hanging][:budgets]
    default = cfg[:hanging][:default_budget]
    named = Map.keys(budgets)

    classes =
      [
        {default, :default}
        | budgets |> Enum.group_by(&elem(&1, 1), &elem(&1, 0)) |> Enum.to_list()
      ]

    for {budget, workers} <- classes,
        base = hanging_base(orphan_cutoff, DateTime.add(now, -(budget + 1), :second)),
        base = scope_workers(base, workers, named),
        {queue, worker, count, first} <- executing_groups(repo, base, qopts) do
      longest = age(first, now)

      %Finding{
        check: :hanging,
        severity: severity(longest, budget),
        queue: queue,
        worker: worker,
        count: count,
        value: longest,
        threshold: budget,
        message:
          "#{count} job(s) running past their #{budget}s budget (longest #{longest}s). Consider a `timeout/1` callback on the worker.",
        job_ids: sample_ids(repo, scoped(base, queue, worker), qopts)
      }
    end
  end

  defp hanging_base(nil, budget_cutoff) do
    from(j in Job, where: j.state == "executing" and j.attempted_at <= ^budget_cutoff)
  end

  defp hanging_base(orphan_cutoff, budget_cutoff) do
    from(j in Job,
      where:
        j.state == "executing" and j.attempted_at > ^orphan_cutoff and
          j.attempted_at <= ^budget_cutoff
    )
  end

  # Direct Checks.hanging/4 (no run/2 memo) keeps the historical dedup bound.
  defp orphaned_check_enabled? do
    case Process.get({__MODULE__, :only}) do
      nil -> true
      only -> :orphaned in only
    end
  end

  defp scope_workers(base, :default, []), do: base
  defp scope_workers(base, :default, named), do: where(base, [j], j.worker not in ^named)
  defp scope_workers(base, workers, _named), do: where(base, [j], j.worker in ^workers)

  defp executing_groups(repo, base, qopts) do
    base
    |> group_by([j], [j.queue, j.worker])
    |> order_by([j], [j.queue, j.worker])
    |> select(
      [j],
      {j.queue, j.worker, count(j.id), type(min(j.attempted_at), :utc_datetime_usec)}
    )
    |> repo.all(qopts)
  end

  defp scoped(base, queue, worker),
    do: where(base, [j], j.queue == ^queue and j.worker == ^worker)

  # -- due jobs: backlog and stalled queues --------------------------------------------------

  def backlog(repo, cfg, now, qopts) do
    max_depth = cfg[:backlog][:max_depth]
    max_latency = cfg[:backlog][:max_latency]

    for %{queue: queue, count: count, oldest: oldest} <- due_by_queue(repo, now, qopts),
        latency = age(oldest, now),
        count > max_depth or latency > max_latency do
      {value, threshold, what} =
        backlog_evidence(count, max_depth, latency, max_latency)

      %Finding{
        check: :backlog,
        severity: severity(value, threshold),
        queue: queue,
        count: count,
        value: value,
        threshold: threshold,
        message: "Queue #{queue} is backed up: #{what}.",
        job_ids: sample_ids(repo, due_query(now) |> where([j], j.queue == ^queue), qopts)
      }
    end
  end

  # Prefer the strongest breached dimension (critical over warning; then higher
  # ratio). A zero threshold that has already been breached is treated as an
  # infinite ratio so we never divide by zero.
  defp backlog_evidence(count, max_depth, latency, max_latency) do
    depth? = count > max_depth
    latency? = latency > max_latency

    depth = {count, max_depth, "#{count} due jobs (limit #{max_depth})"}

    latency_ev =
      {latency, max_latency,
       "oldest due job waiting #{latency}s (limit #{max_latency}s), #{count} due"}

    cond do
      depth? and latency? ->
        if stronger_breach?(latency, max_latency, count, max_depth),
          do: latency_ev,
          else: depth

      latency? ->
        latency_ev

      true ->
        depth
    end
  end

  defp stronger_breach?(left_value, left_threshold, right_value, right_threshold) do
    left_rank = severity_rank(left_value, left_threshold)
    right_rank = severity_rank(right_value, right_threshold)

    left_rank > right_rank or
      (left_rank == right_rank and
         breach_ratio(left_value, left_threshold) >
           breach_ratio(right_value, right_threshold))
  end

  defp severity_rank(_value, 0), do: 2
  defp severity_rank(value, threshold) when value >= 2 * threshold, do: 2
  defp severity_rank(_value, _threshold), do: 1

  defp breach_ratio(_value, 0), do: :infinity
  defp breach_ratio(value, threshold), do: value / threshold

  # A late queue is "active" when any of its jobs was attempted within the window. Nothing
  # indexes attempted_at, so this runs only for late queues (usually none), as a series of
  # `LIMIT 1` probes, each bounded by an index range, cheapest first:
  #   1. executing, 2. scheduled/retryable (snoozed or retried), 3. discarded / cancelled
  #   in the window (their own (state, *_at) indexes), 4. completed, restricted to jobs
  #   scheduled no earlier than `lookback` seconds before the queue's oldest due job, which
  #   keeps the index range small. Oban fetches by priority, then scheduled_at, so the jobs a
  #   running queue picked up recently were scheduled shortly before (or after) its oldest
  #   waiting job. For a truly stopped queue the range holds few rows, so the probe is cheap
  #   exactly when the check fires.
  def stalled(repo, cfg, now, qopts) do
    max_latency = cfg[:backlog][:max_latency]
    window = cfg[:stalled][:window]
    cutoff = DateTime.add(now, -window, :second)
    lookback = cfg[:stalled][:lookback]

    for %{queue: queue, count: count, oldest: oldest} <- due_by_queue(repo, now, qopts),
        latency = age(oldest, now),
        latency > max_latency,
        since = DateTime.add(now, -(latency + lookback), :second),
        not attempted_since?(repo, queue, cutoff, since, qopts) do
      %Finding{
        check: :stalled,
        severity: :critical,
        queue: queue,
        count: count,
        value: latency,
        threshold: max_latency,
        message:
          "Queue #{queue} looks stalled: #{count} due job(s), oldest #{latency}s, and no job attempted in the last #{window}s. Check the queue is configured and running on some node, isn't paused, and that leadership/notifier work.",
        job_ids: sample_ids(repo, due_query(now) |> where([j], j.queue == ^queue), qopts)
      }
    end
  end

  defp attempted_since?(repo, queue, cutoff, since, qopts) do
    [
      from(j in Job, where: j.state == "executing" and j.attempted_at >= ^cutoff),
      # snoozed/retried jobs are rescheduled after their attempt: scheduled_at >= attempted_at
      from(j in Job,
        where:
          j.state in ["scheduled", "retryable"] and j.scheduled_at >= ^cutoff and
            j.attempted_at >= ^cutoff
      ),
      from(j in Job,
        where: j.state == "discarded" and j.discarded_at >= ^cutoff and j.attempted_at >= ^cutoff
      ),
      from(j in Job,
        where: j.state == "cancelled" and j.cancelled_at >= ^cutoff and j.attempted_at >= ^cutoff
      ),
      from(j in Job,
        where: j.state == "completed" and j.scheduled_at >= ^since and j.attempted_at >= ^cutoff
      )
    ]
    |> Enum.any?(fn probe ->
      probe
      |> where([j], j.queue == ^queue)
      |> select([j], j.id)
      |> limit(1)
      |> repo.all(qopts)
      |> Kernel.!=([])
    end)
  end

  # The redundant `state IN (...)` gives the planner an index condition on the leading
  # column of Oban's (state, queue, priority, scheduled_at, id) index.
  defp due_query(now) do
    from(j in Job,
      where:
        j.state in ["available", "scheduled", "retryable"] and
          (j.state == "available" or j.scheduled_at <= ^now)
    )
  end

  # Shared by :backlog and :stalled; memoized for the duration of one QueueKeeperCheck.run/2.
  defp due_by_queue(repo, now, qopts) do
    memo(:due_by_queue, {repo, now, qopts}, fn ->
      due_query(now)
      |> group_by([j], j.queue)
      |> order_by([j], j.queue)
      |> select([j], %{
        queue: j.queue,
        count: count(j.id),
        oldest: type(min(j.scheduled_at), :utc_datetime_usec)
      })
      |> repo.all(qopts)
    end)
  end

  @doc false
  def with_memo(fun, opts \\ []) do
    Process.put({__MODULE__, :memo}, %{})
    Process.put({__MODULE__, :only}, Keyword.get(opts, :only))

    try do
      fun.()
    after
      Process.delete({__MODULE__, :memo})
      Process.delete({__MODULE__, :only})
    end
  end

  defp memo(name, key, fun) do
    case Process.get({__MODULE__, :memo}) do
      nil ->
        fun.()

      %{} = memo ->
        case Map.fetch(memo, {name, key}) do
          {:ok, value} ->
            value

          :error ->
            value = fun.()
            Process.put({__MODULE__, :memo}, Map.put(memo, {name, key}, value))
            value
        end
    end
  end

  # -- failure patterns: retry storms, discard and cancel spikes ----------------------------

  def retry_storm(repo, cfg, now, qopts) do
    window = cfg[:retry_storm][:window]
    min = cfg[:retry_storm][:min_retries]
    cutoff = DateTime.add(now, -window, :second)

    # Every part honors the window. Each is index-friendly: state-prefixed ranges on the
    # composite (state, queue, priority, scheduled_at, id) index, or the
    # (state, discarded_at) / (state, cancelled_at) indexes. Completed jobs have no index on
    # a timestamp, so counting them is opt-in.
    #
    # Retryable jobs count when their last failed attempt started in the window
    # (`attempted_at >= cutoff`). Oban reschedules a failed job after its attempt
    # (`scheduled_at = time of failure + backoff`), so `scheduled_at >= cutoff` is implied;
    # it is repeated so the planner can discard most out-of-window rows inside the
    # composite index before reading `attempted_at` from the table.
    parts =
      [
        from(j in Job,
          where:
            j.state == "retryable" and j.scheduled_at >= ^cutoff and j.attempted_at >= ^cutoff
        ),
        from(j in Job,
          where: j.state == "executing" and j.attempt >= 2 and j.attempted_at >= ^cutoff
        ),
        from(j in Job,
          where: j.state == "discarded" and j.discarded_at >= ^cutoff and j.attempt >= 2
        ),
        from(j in Job,
          where: j.state == "cancelled" and j.cancelled_at >= ^cutoff and j.attempt >= 2
        )
      ] ++
        if cfg[:retry_storm][:include_completed],
          do: [
            from(j in Job,
              where: j.state == "completed" and j.attempt >= 2 and j.attempted_at >= ^cutoff
            )
          ],
          else: []

    rows = Enum.flat_map(parts, &grouped_by_worker(repo, &1, qopts))

    findings_per_worker(rows, min, fn worker, count ->
      {:retry_storm, count, min,
       "Retry storm in #{worker}: #{count} job(s) failed and awaiting retry, or retried, in the last #{window}s (limit #{min})."}
    end)
    |> Enum.map(fn finding ->
      ids =
        Enum.reduce_while(parts, [], fn part, acc ->
          acc = acc ++ sample_ids(repo, scoped_worker(part, finding.worker), qopts)
          if length(acc) >= @sample, do: {:halt, acc}, else: {:cont, acc}
        end)

      %{finding | job_ids: ids |> Enum.sort() |> Enum.take(@sample)}
    end)
  end

  def discarded(repo, cfg, now, qopts) do
    spike(
      repo,
      cfg,
      now,
      qopts,
      :discarded,
      "discarded",
      :discarded_at,
      "exhausted their attempts or were discarded"
    )
  end

  def cancelled(repo, cfg, now, qopts) do
    spike(repo, cfg, now, qopts, :cancelled, "cancelled", :cancelled_at, "were cancelled")
  end

  defp spike(repo, cfg, now, qopts, check, state, field, verb) do
    window = cfg[check][:window]
    max = cfg[check][:max]
    cutoff = DateTime.add(now, -window, :second)
    base = from(j in Job, where: j.state == ^state and field(j, ^field) >= ^cutoff)

    repo
    |> grouped_by_worker(base, qopts)
    |> findings_per_worker(max, fn worker, count ->
      {check, count, max,
       "#{count} #{worker} job(s) #{verb} in the last #{window}s (limit #{max}). These fail silently unless something alerts on them."}
    end)
    |> Enum.map(fn finding ->
      %{finding | job_ids: sample_ids(repo, scoped_worker(base, finding.worker), qopts)}
    end)
  end

  # -- missing insertions (cron jobs that silently stopped) ------------------------------
  # Opt-in: `expected` maps worker name => max seconds between insertions. Looks at the newest
  # row for each worker in any state, so the Pruner's `max_age` must exceed the largest gap.
  #
  # Cost: `worker` and `inserted_at` are not indexed by Oban, so on Postgres this is one
  # sequential (parallel) scan of oban_jobs per run, bounded by `statement_timeout`. It is
  # the only check without index support; see docs/SECURITY_REVIEW.md for numbers.

  def cron_missing(repo, cfg, now, qopts) do
    expected = cfg[:cron_missing][:expected]

    if map_size(expected) == 0 do
      []
    else
      workers = Map.keys(expected)

      latest =
        from(j in Job,
          where: j.worker in ^workers,
          group_by: j.worker,
          select: {j.worker, type(max(j.inserted_at), :utc_datetime_usec), max(j.id)}
        )
        |> repo.all(qopts)
        |> Map.new(fn {w, at, id} -> {w, {at, id}} end)

      for {worker, max_gap} <- Enum.sort(expected),
          {at, id} = Map.get(latest, worker, {nil, nil}),
          is_nil(at) or age(at, now) > max_gap do
        {value, detail} =
          if at,
            do: {age(at, now), "last inserted #{age(at, now)}s ago"},
            else: {nil, "no rows at all (never inserted, or pruned)"}

        %Finding{
          check: :cron_missing,
          severity: :critical,
          worker: worker,
          count: 0,
          value: value,
          threshold: max_gap,
          job_ids: List.wrap(id),
          message:
            "no #{worker} job inserted within #{max_gap}s: #{detail}. Cron plugin not running, crontab entry removed, or the Pruner deleted history (raise its max_age above #{max_gap}s)."
        }
      end
    end
  end

  # -- dead workers (dead code paths) ----------------------------------------------------
  # Opt-in: set `window_days` to any positive integer (7, 14 and 30 are common examples;
  # if you only set `known` or `discover: true`, the window defaults to 7). Last activity
  # is last enqueue, not last execution.
  #
  # Prefer the opt-in last-seen ledger (`QueueKeeperCheck.Ledger`) when it is present:
  # one row per worker, no need to raise Pruner max_age, and a cheap read. Until the
  # ledger itself has been recording for the window, stay silent (or emit
  # `report_short_history`). Without a ledger, fall back to `max(inserted_at)` on
  # oban_jobs; if the oldest finished row is newer than the window, do not flag.
  #
  # When a worker is flagged for no recent enqueue, a second, state-bounded
  # query reports leftover nonterminal jobs (including future `scheduled` and
  # core/Pro `suspended`). No recent enqueue is not treated as unused code.
  #
  # Cost of the fallback: `worker` and `inserted_at` are not indexed by Oban, so that
  # path is a sequential scan of oban_jobs, like `:cron_missing`, bounded by
  # `statement_timeout`. The pending-job query is filtered on `state IN (...)`
  # and can use Oban's standard state-prefixed indexes.

  @default_dead_window_days 7
  @seconds_per_day 86_400

  def dead_workers(repo, cfg, now, qopts) do
    uw = cfg[:dead_workers]
    window_days = uw[:window_days]
    known = uw[:known]
    discover? = uw[:discover]

    if not (is_integer(window_days) or known != [] or discover?) do
      []
    else
      dead_workers_run(repo, cfg, now, qopts, window_days || @default_dead_window_days)
    end
  end

  defp dead_workers_run(repo, cfg, now, qopts, default_days) do
    uw = cfg[:dead_workers]

    skip =
      MapSet.new(uw[:ignore])
      |> MapSet.union(MapSet.new(Map.keys(cfg[:cron_missing][:expected])))

    candidates =
      uw[:known]
      |> Enum.concat(if(uw[:discover], do: discovered_workers(), else: []))
      |> Enum.uniq()

    {source, history_secs, latest} = dead_workers_activity(repo, uw, now, qopts)
    pending = pending_by_worker(repo, qopts)

    workers =
      latest
      |> Map.keys()
      |> Enum.concat(candidates)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(skip, &1))
      |> Enum.sort()

    findings =
      for worker <- workers,
          days = Map.get(uw[:overrides], worker, default_days),
          window_secs = days * @seconds_per_day,
          history_secs >= window_secs,
          {at, id, n} = Map.get(latest, worker, {nil, nil, 0}),
          is_nil(at) or age(at, now) > window_secs do
        {pending_status, pending_count, next_at, pending_id} =
          case pending do
            {:ok, map} ->
              {n, at, id} = Map.get(map, worker, {0, nil, nil})
              {:ok, n, at, id}

            :error ->
              {:error, 0, nil, nil}
          end

        {value, detail} =
          if at,
            do: {age(at, now), "last inserted #{age(at, now)}s ago"},
            else: {nil, "no rows at all (never inserted, or pruned)"}

        job_ids =
          [id, pending_id]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        %Finding{
          check: :dead_workers,
          severity: :warning,
          worker: worker,
          count: max(n, pending_count),
          value: value,
          threshold: window_secs,
          job_ids: job_ids,
          message:
            inactivity_message(
              worker,
              days,
              window_secs,
              detail,
              pending_status,
              pending_count,
              next_at,
              now
            )
        }
      end

    if uw[:report_short_history] and history_secs < default_days * @seconds_per_day do
      threshold = default_days * @seconds_per_day

      [
        %Finding{
          check: :dead_workers,
          severity: :warning,
          count: 0,
          value: history_secs,
          threshold: threshold,
          message: short_history_message(source, default_days, threshold, history_secs)
        }
        | findings
      ]
    else
      findings
    end
  end

  defp dead_workers_activity(repo, uw, now, qopts) do
    if uw[:use_ledger] do
      case QueueKeeperCheck.Ledger.fetch(repo, qopts_to_opts(qopts)) do
        {:ok, %{started_at: started, sightings: latest}} ->
          {:ledger, age(started, now), latest}

        :absent ->
          dead_workers_from_jobs(repo, now, qopts)
      end
    else
      dead_workers_from_jobs(repo, now, qopts)
    end
  end

  defp dead_workers_from_jobs(repo, now, qopts) do
    oldest_finished =
      from(j in Job,
        where: j.state in ["completed", "cancelled", "discarded"],
        select: type(min(j.inserted_at), :utc_datetime_usec)
      )
      |> repo.one(qopts)

    history_secs = if oldest_finished, do: age(oldest_finished, now), else: 0

    latest =
      from(j in Job,
        group_by: j.worker,
        select: {j.worker, type(max(j.inserted_at), :utc_datetime_usec), max(j.id), count(j.id)}
      )
      |> repo.all(qopts)
      |> Map.new(fn {w, at, id, n} -> {w, {at, id, n}} end)

    {:jobs, history_secs, latest}
  end

  # -- combined dead-worker candidates (opt-in) ------------------------------------------
  # Report-only combination of enqueue inactivity and the static scan.
  # High confidence requires both signals, sufficient history, a complete
  # scan, and no leftover nonterminal/future jobs. Never claims a worker is
  # definitely dead. See QueueKeeperCheck.DeadWorkerCandidates.

  def dead_worker_candidates(repo, cfg, now, qopts) do
    dwc = cfg[:dead_worker_candidates]
    window_days = dwc[:window_days]
    known = dwc[:known]
    discover? = dwc[:discover]

    if not (is_integer(window_days) or known != [] or discover?) do
      []
    else
      days = window_days || QueueKeeperCheck.DeadWorkerCandidates.default_window_days()
      dead_worker_candidates_run(repo, cfg, now, qopts, days)
    end
  end

  defp dead_worker_candidates_run(repo, cfg, now, qopts, default_days) do
    dwc = cfg[:dead_worker_candidates]

    skip =
      MapSet.new(dwc[:ignore])
      |> MapSet.union(MapSet.new(Map.keys(cfg[:cron_missing][:expected])))

    {_source, history_secs, latest} = dead_workers_activity(repo, dwc, now, qopts)
    pending = pending_by_worker(repo, qopts)

    scan = List.wrap(dwc[:scan])

    scan_opts =
      scan
      |> Keyword.merge(
        known: Enum.uniq(List.wrap(dwc[:known]) ++ List.wrap(Keyword.get(scan, :known)))
      )
      |> Keyword.put_new(:ignore, dwc[:ignore])

    {scan_by, coverage} =
      try do
        report = QueueKeeperCheck.DeadCode.scan_report(scan_opts)
        {Map.new(report.workers, &{&1.worker, &1}), report.coverage}
      rescue
        _ ->
          {%{}, %{complete?: false}}
      end

    # Per-worker windows (including shorter overrides) are evaluated in
    # classify/1 via history_ok?. A short default window must not hide a
    # worker whose override still fits the observed history, and a long
    # override must still be insufficient when history is shorter than it.
    candidates =
      latest
      |> Map.keys()
      |> Enum.concat(dwc[:known])
      |> Enum.concat(if(dwc[:discover], do: discovered_workers(), else: []))
      |> Enum.concat(Map.keys(scan_by))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(skip, &1))
      |> Enum.sort()

    for worker <- candidates,
        days = Map.get(dwc[:overrides], worker, default_days),
        worker_window = QueueKeeperCheck.DeadWorkerCandidates.window_seconds(days) do
      {at, id, n} = Map.get(latest, worker, {nil, nil, 0})

      {pending_status, pending_count, next_at, pending_id} =
        case pending do
          {:ok, map} ->
            {pn, pat, pid} = Map.get(map, worker, {0, nil, nil})
            {:ok, pn, pat, pid}

          :error ->
            {:error, 0, nil, nil}
        end

      {static, static_reason, static_files} =
        case Map.get(scan_by, worker) do
          %{status: :live, reason: reason, files: files} ->
            {:referenced, reason, files}

          %{status: :review_candidate, reason: reason, files: files} ->
            {:unreferenced, reason, files}

          nil ->
            {:not_in_scan, nil, []}
        end

      # `:complete` on scan: is a test/operator override. Injected `:callers`
      # otherwise make DeadCode.scan_report/1 report complete?: false.
      scan_complete? =
        case Keyword.get(scan, :complete) do
          flag when is_boolean(flag) -> flag
          _ -> coverage[:complete?] == true
        end

      attrs = %{
        worker: worker,
        history_secs: history_secs,
        window_secs: worker_window,
        window_days: days,
        now: now,
        last_inserted_at: at,
        pending_status: pending_status,
        pending_count: pending_count,
        next_scheduled_at: next_at,
        static: static,
        static_reason: static_reason,
        static_files: static_files,
        scan_complete?: scan_complete?
      }

      case QueueKeeperCheck.DeadWorkerCandidates.classify(attrs) do
        :omit ->
          nil

        {reason, message} ->
          job_ids =
            [id, pending_id]
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          %Finding{
            check: :dead_worker_candidates,
            severity: :warning,
            reason: reason,
            worker: worker,
            count: max(n, pending_count),
            value: QueueKeeperCheck.DeadWorkerCandidates.age(at, now),
            threshold: worker_window,
            job_ids: job_ids,
            message: message
          }
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # -- persisted jobs (opt-in inventory reconciliation) -----------------------------------
  # Report-only. Compares nonterminal jobs, including future scheduled and core
  # `suspended`, to an operator-supplied inventory. One run is one prefix; never
  # infer deployment-wide absence from this node; never create atoms from DB
  # worker or queue strings. Oban Pro beyond core `suspended` is untested.

  def persisted_jobs(repo, cfg, now, qopts) do
    pj = cfg[:persisted_jobs]

    if persisted_jobs_enabled?(pj) do
      persisted_jobs_run(repo, cfg, now, qopts, pj)
    else
      []
    end
  end

  defp persisted_jobs_enabled?(pj) do
    pj[:workers] != [] or pj[:previous_workers] != [] or pj[:queues] != [] or
      pj[:paused_queues] != [] or pj[:discover] or pj[:consumers] != :unknown
  end

  defp persisted_jobs_run(repo, _cfg, now, qopts, pj) do
    ignore_workers = MapSet.new(pj[:ignore_workers])
    ignore_queues = MapSet.new(pj[:ignore_queues])
    paused = MapSet.new(pj[:paused_queues])
    queues = MapSet.new(pj[:queues])
    previous = MapSet.new(pj[:previous_workers])
    explicit = MapSet.union(MapSet.new(pj[:workers]), previous)

    discovered = if pj[:discover], do: discovered_workers(), else: []
    workers = Enum.reduce(discovered, explicit, &MapSet.put(&2, &1))
    worker_inventory? = MapSet.size(explicit) > 0 or discovered != []

    rows = nonterminal_groups(repo, qopts)

    by_worker = group_pending(rows, fn {_q, w, _s, n, at, id} -> {w, n, at, id} end)
    by_queue = group_pending(rows, fn {q, _w, _s, n, at, id} -> {q, n, at, id} end)

    findings = []

    findings =
      findings ++
        worker_findings(
          repo,
          qopts,
          now,
          by_worker,
          workers,
          worker_inventory?,
          pj,
          ignore_workers
        )

    findings =
      findings ++
        queue_findings(
          repo,
          qopts,
          now,
          by_queue,
          queues,
          paused,
          pj,
          ignore_queues
        )

    findings
  end

  defp nonterminal_groups(repo, qopts) do
    from(j in Job,
      where: j.state in @incomplete_job_states,
      group_by: [j.queue, j.worker, j.state],
      select:
        {j.queue, j.worker, j.state, count(j.id), type(min(j.scheduled_at), :utc_datetime_usec),
         max(j.id)}
    )
    |> repo.all(qopts)
  end

  defp group_pending(rows, fun) do
    Enum.reduce(rows, %{}, fn row, acc ->
      {key, n, at, id} = fun.(row)

      Map.update(acc, key, {n, at, [id]}, fn {n0, at0, ids} ->
        {n0 + n, earlier_dt(at0, at), [id | ids]}
      end)
    end)
  end

  defp earlier_dt(nil, other), do: other
  defp earlier_dt(other, nil), do: other

  defp earlier_dt(a, b) do
    if DateTime.compare(a, b) == :gt, do: b, else: a
  end

  defp worker_findings(repo, qopts, now, by_worker, workers, worker_inventory?, pj, ignore) do
    cond do
      pj[:discover] and not worker_inventory? ->
        [
          %Finding{
            check: :persisted_jobs,
            severity: :warning,
            reason: :insufficient_evidence,
            count: 0,
            message:
              "persisted_jobs discover: true found no Oban.Worker modules. " <>
                "The host app is probably not started (mix queue_keeper.check and " <>
                "Release start only the repo). Cannot classify missing workers from " <>
                "this node; pass an explicit workers list, or run from a node that " <>
                "has loaded the application."
          }
        ]

      not worker_inventory? ->
        []

      true ->
        for {worker, {n, next_at, ids}} <- Enum.sort(by_worker),
            not MapSet.member?(ignore, worker),
            not MapSet.member?(workers, worker) do
          %Finding{
            check: :persisted_jobs,
            severity: :warning,
            reason: :missing_worker,
            worker: worker,
            count: n,
            value: n,
            job_ids: sample_or_ids(repo, qopts, worker, nil, ids),
            message:
              "#{worker} has #{n} nonterminal job(s) (available, scheduled, retryable, " <>
                "executing, or suspended), including future-scheduled work, but is not " <>
                "in the deployed worker inventory" <>
                next_sched_suffix(next_at, now) <>
                ". The worker module may have been removed or renamed; during a " <>
                "rollout add the old name to previous_workers. This does not mean " <>
                "the job cannot run on another node still serving the old release."
          }
        end
    end
  end

  defp queue_findings(repo, qopts, now, by_queue, queues, paused, pj, ignore) do
    enumerated? = pj[:dynamic_queues] == :enumerated
    queue_list? = MapSet.size(queues) > 0 or enumerated?
    consumers = pj[:consumers]

    Enum.flat_map(Enum.sort(by_queue), fn {queue, {n, next_at, ids}} ->
      if MapSet.member?(ignore, queue) do
        []
      else
        paused? = MapSet.member?(paused, queue)
        listed? = MapSet.member?(queues, queue)
        suffix = next_sched_suffix(next_at, now)
        ids = sample_or_ids(repo, qopts, nil, queue, ids)

        paused_finding =
          if paused? do
            [
              %Finding{
                check: :persisted_jobs,
                severity: :warning,
                reason: :paused_queue,
                queue: queue,
                count: n,
                value: n,
                job_ids: ids,
                message:
                  "Queue #{queue} has #{n} nonterminal job(s) and is listed in " <>
                    "paused_queues" <>
                    suffix <>
                    ". Jobs will not execute until the queue is resumed. Pause " <>
                    "state is taken only from the options you passed, not from " <>
                    "this node's Oban process."
              }
            ]
          else
            []
          end

        unconfigured =
          cond do
            listed? ->
              []

            enumerated? and not listed? ->
              [
                %Finding{
                  check: :persisted_jobs,
                  severity: :warning,
                  reason: :unconfigured_queue,
                  queue: queue,
                  count: n,
                  value: n,
                  job_ids: ids,
                  message:
                    "Queue #{queue} has #{n} nonterminal job(s) but is not in the " <>
                      "effective queue inventory (dynamic_queues: :enumerated)" <>
                      suffix <>
                      ". The consumer config may have been removed. This is not " <>
                      "proof that no node still consumes the queue."
                }
              ]

            queue_list? and not listed? ->
              [
                %Finding{
                  check: :persisted_jobs,
                  severity: :warning,
                  reason: :insufficient_evidence,
                  queue: queue,
                  count: n,
                  value: n,
                  job_ids: ids,
                  message:
                    "Queue #{queue} has #{n} nonterminal job(s) and is not in the " <>
                      "queues list, but dynamic_queues is :unknown, so this may be a " <>
                      "dynamic queue rather than an unconfigured one" <>
                      suffix <>
                      ". Set dynamic_queues: :enumerated if the list is complete."
                }
              ]

            true ->
              []
          end

        no_consumer =
          cond do
            consumers == :unknown ->
              []

            is_list(consumers) and queue in consumers ->
              []

            is_list(consumers) ->
              [
                %Finding{
                  check: :persisted_jobs,
                  severity: :warning,
                  reason: :no_active_consumer,
                  queue: queue,
                  count: n,
                  value: n,
                  job_ids: ids,
                  message:
                    "Queue #{queue} has #{n} nonterminal job(s) and is not in the " <>
                      "supplied consumers snapshot" <>
                      suffix <>
                      ". The snapshot is taken as cluster-wide; this check never " <>
                      "infers a missing consumer from a single node."
                }
              ]

            true ->
              []
          end

        paused_finding ++ unconfigured ++ no_consumer
      end
    end)
  end

  defp next_sched_suffix(nil, _now), do: ""

  defp next_sched_suffix(at, now) do
    rel = DateTime.diff(at, now)

    if rel > 0 do
      "; next scheduled_at is #{rel}s from now"
    else
      "; oldest scheduled_at is #{-rel}s ago"
    end
  end

  defp sample_or_ids(repo, qopts, worker, queue, ids) do
    query =
      from(j in Job, where: j.state in @incomplete_job_states)
      |> then(fn q -> if worker, do: where(q, [j], j.worker == ^worker), else: q end)
      |> then(fn q -> if queue, do: where(q, [j], j.queue == ^queue), else: q end)

    case sample_ids(repo, query, qopts) do
      [] -> ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort() |> Enum.take(10)
      sampled -> sampled
    end
  end

  defp qopts_to_opts(qopts), do: Keyword.take(qopts, [:prefix])

  defp short_history_message(:ledger, days, threshold, history_secs) do
    history_desc = if history_secs > 0, do: "#{history_secs}s", else: "just started"

    "dead_workers window (#{days} days / #{threshold}s) exceeds the ledger's recording " <>
      "age (#{history_desc}). Insufficient history to report enqueue inactivity without " <>
      "false positives. Keep the ledger attached; findings start once it has been " <>
      "recording for #{days} days. Do not raise the Pruner max_age just for this check."
  end

  defp short_history_message(:jobs, days, threshold, history_secs) do
    history_desc = if history_secs > 0, do: "#{history_secs}s", else: "no finished rows"

    "dead_workers window (#{days} days / #{threshold}s) exceeds observable " <>
      "finished-job history (#{history_desc}). Insufficient history to report enqueue " <>
      "inactivity without false positives. Attach QueueKeeperCheck.Ledger so this " <>
      "check does not depend on Pruner retention, or shrink window_days."
  end

  defp pending_by_worker(repo, qopts) do
    # Rescued: a failed pending SELECT must not drop the inactivity findings
    # (SQLite/MySQL may reject a schema prefix that only applies to Postgres).
    try do
      rows =
        from(j in Job,
          where: j.state in @incomplete_job_states,
          group_by: j.worker,
          select:
            {j.worker, count(j.id), type(min(j.scheduled_at), :utc_datetime_usec), max(j.id)}
        )
        |> repo.all(qopts)

      {:ok, Map.new(rows, fn {w, n, at, id} -> {w, {n, at, id}} end)}
    rescue
      _ -> :error
    end
  end

  defp inactivity_message(
         worker,
         days,
         window_secs,
         detail,
         pending_status,
         pending_count,
         next_at,
         now
       ) do
    base =
      "#{worker} has had no job inserted within #{days} days (#{window_secs}s): #{detail}."

    cond do
      pending_status == :error ->
        base <>
          " Could not query leftover nonterminal jobs (insufficient evidence about " <>
          "pending work). This is enqueue inactivity, not proof of unused code; add " <>
          "the worker to dead_workers ignore, or a longer per-worker override, if it " <>
          "is meant to run rarely."

      pending_count > 0 ->
        next =
          cond do
            is_nil(next_at) ->
              ""

            DateTime.compare(next_at, now) == :gt ->
              " next scheduled_at is #{DateTime.diff(next_at, now)}s from now"

            true ->
              " oldest pending scheduled_at is #{DateTime.diff(now, next_at)}s ago"
          end

        base <>
          " #{pending_count} job(s) are still pending in nonterminal states" <>
          " (available, scheduled, retryable, executing, or suspended);" <>
          next <>
          ". No recent enqueue is not evidence of unused code."

      true ->
        base <>
          " No nonterminal jobs remain for this worker. This is enqueue inactivity, " <>
          "not proof of unused code; add the worker to dead_workers ignore, or a " <>
          "longer per-worker override, if it is meant to run rarely."
    end
  end

  defp discovered_workers do
    otp_root = :code.root_dir() |> List.to_string()

    for {app, _, _} <- Application.loaded_applications(),
        lib_dir = :code.lib_dir(app),
        is_list(lib_dir),
        not String.starts_with?(List.to_string(lib_dir), otp_root),
        modules when is_list(modules) <- [Application.spec(app, :modules)],
        mod <- modules,
        match?({:module, _}, Code.ensure_loaded(mod)),
        function_exported?(mod, :perform, 1),
        function_exported?(mod, :__opts__, 0),
        worker_module?(mod),
        do: module_worker_name(mod)
  end

  defp worker_module?(mod) do
    opts = mod.__opts__()
    is_list(opts) and Keyword.has_key?(opts, :queue)
  rescue
    _ -> false
  end

  defp module_worker_name(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> rest -> rest
      name -> name
    end
  end

  defp grouped_by_worker(repo, base, qopts) do
    base
    |> group_by([j], [j.worker, j.queue])
    |> select([j], {j.worker, j.queue, count(j.id)})
    |> repo.all(qopts)
  end

  defp findings_per_worker(rows, threshold, describe) do
    rows
    |> Enum.group_by(fn {w, _, _} -> w end)
    |> Enum.sort()
    |> Enum.flat_map(fn {worker, list} ->
      count = list |> Enum.map(&elem(&1, 2)) |> Enum.sum()

      if count >= threshold do
        {check, value, limit, message} = describe.(worker, count)
        queues = list |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() |> Enum.join(",")

        [
          %Finding{
            check: check,
            severity: severity(value, limit),
            queue: queues,
            worker: worker,
            count: count,
            value: value,
            threshold: limit,
            message: message
          }
        ]
      else
        []
      end
    end)
  end

  defp scoped_worker(base, worker), do: where(base, [j], j.worker == ^worker)

  # -- helpers ---------------------------------------------------------------------------------

  # Up to @sample ids, sorted in Elixir. No ORDER BY in SQL: with a LIMIT, ordering by id
  # can make the planner walk the primary key across the whole table looking for matches.
  # Within one QueueKeeperCheck.run/2 at most @sample_queries sample queries run in total
  # (findings beyond that get `job_ids: []`), so a pathological number of findings (e.g.
  # thousands of workers) cannot turn into thousands of extra queries.
  defp sample_ids(repo, query, qopts) do
    if take_sample_budget(), do: fetch_sample_ids(repo, query, qopts), else: []
  end

  defp take_sample_budget do
    case Process.get({__MODULE__, :memo}) do
      nil ->
        true

      memo ->
        used = Map.get(memo, :samples_used, 0)
        Process.put({__MODULE__, :memo}, Map.put(memo, :samples_used, used + 1))
        used < @sample_queries
    end
  end

  defp fetch_sample_ids(repo, query, qopts) do
    query
    |> exclude(:order_by)
    |> select([j], j.id)
    |> limit(@sample)
    |> repo.all(qopts)
    |> Enum.sort()
  end

  defp age(nil, _now), do: 0
  defp age(%NaiveDateTime{} = t, now), do: age(DateTime.from_naive!(t, "Etc/UTC"), now)
  defp age(%DateTime{} = t, now), do: max(DateTime.diff(now, t, :second), 0)

  defp severity(value, threshold) when value >= 2 * threshold, do: :critical
  defp severity(_value, _threshold), do: :warning
end
