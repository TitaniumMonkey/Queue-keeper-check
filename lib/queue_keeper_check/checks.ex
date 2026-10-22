defmodule QueueKeeperCheck.Checks do
  @moduledoc """
  The individual checks. Each takes `(repo, config, now, query_opts)` and returns a list of
  `QueueKeeperCheck.Finding` structs. `QueueKeeperCheck.run/2` wraps each call in
  `QueueKeeperCheck.Guard`; call these directly only if you apply your own limits.

  Every query is a plain `SELECT` on `oban_jobs` that reads only `id`, `state`, `queue`,
  `worker`, `attempt` and timestamp columns. `args`, `meta`, `errors`, `tags` and
  `attempted_by` are never selected or filtered on. Each query is either an aggregate
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
    orphan_cutoff = DateTime.add(now, -cfg[:orphaned][:after], :second)
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

  defp hanging_base(orphan_cutoff, budget_cutoff) do
    from(j in Job,
      where:
        j.state == "executing" and j.attempted_at > ^orphan_cutoff and
          j.attempted_at <= ^budget_cutoff
    )
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
        if latency > max_latency,
          do:
            {latency, max_latency,
             "oldest due job waiting #{latency}s (limit #{max_latency}s), #{count} due"},
          else: {count, max_depth, "#{count} due jobs (limit #{max_depth})"}

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
      from(j in Job, where: j.state == "discarded" and j.discarded_at >= ^cutoff),
      from(j in Job, where: j.state == "cancelled" and j.cancelled_at >= ^cutoff),
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
  def with_memo(fun) do
    Process.put({__MODULE__, :memo}, %{})

    try do
      fun.()
    after
      Process.delete({__MODULE__, :memo})
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
