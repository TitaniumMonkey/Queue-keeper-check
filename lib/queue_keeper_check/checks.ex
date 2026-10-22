defmodule QueueKeeperCheck.Checks do
  @moduledoc """
  The individual checks. Each takes `(repo, config, now, query_opts)` and returns a list of
  `QueueKeeperCheck.Finding` structs. All queries are read-only aggregates on `oban_jobs`;
  job `args` are never read.
  """
  import Ecto.Query
  alias Oban.Job
  alias QueueKeeperCheck.Finding

  @sample 10

  # -- executing jobs: orphaned and hanging -----------------------------------------------
  # Executing rows are bounded by total queue concurrency, so we load them and decide in Elixir.

  def orphaned(repo, cfg, now, qopts) do
    limit = cfg[:orphaned][:after]

    repo
    |> executing(qopts)
    |> Enum.filter(&(age(&1.attempted_at, now) >= limit))
    |> group_findings(:orphaned, fn group ->
      oldest = group |> Enum.map(&age(&1.attempted_at, now)) |> Enum.max()

      {:critical, oldest, limit,
       "#{length(group)} job(s) stuck in executing for up to #{oldest}s (limit #{limit}s); the node running them probably died. Oban's Lifeline plugin rescues these."}
    end)
  end

  def hanging(repo, cfg, now, qopts) do
    orphan_after = cfg[:orphaned][:after]
    budgets = cfg[:hanging][:budgets]
    default = cfg[:hanging][:default_budget]

    repo
    |> executing(qopts)
    |> Enum.filter(fn job ->
      a = age(job.attempted_at, now)
      a < orphan_after and a > Map.get(budgets, job.worker, default)
    end)
    |> group_findings(:hanging, fn [first | _] = group ->
      budget = Map.get(budgets, first.worker, default)
      longest = group |> Enum.map(&age(&1.attempted_at, now)) |> Enum.max()

      {severity(longest, budget), longest, budget,
       "#{length(group)} job(s) running past their #{budget}s budget (longest #{longest}s). Consider a `timeout/1` callback on the worker."}
    end)
  end

  defp executing(repo, qopts) do
    from(j in Job,
      where: j.state == "executing",
      select: %{id: j.id, queue: j.queue, worker: j.worker, attempted_at: j.attempted_at}
    )
    |> repo.all(qopts)
  end

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

  def stalled(repo, cfg, now, qopts) do
    max_latency = cfg[:backlog][:max_latency]
    window = cfg[:stalled][:window]
    cutoff = DateTime.add(now, -window, :second)

    late =
      for %{oldest: o} = row <- due_by_queue(repo, now, qopts), age(o, now) > max_latency, do: row

    queues = Enum.map(late, & &1.queue)

    active =
      from(j in Job,
        where: j.queue in ^queues and not is_nil(j.attempted_at) and j.attempted_at >= ^cutoff,
        distinct: true,
        select: j.queue
      )
      |> repo.all(qopts)
      |> MapSet.new()

    for %{queue: queue, count: count, oldest: oldest} <- late,
        not MapSet.member?(active, queue) do
      latency = age(oldest, now)

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

  defp due_query(now) do
    from(j in Job,
      where:
        j.state == "available" or
          (j.state in ["scheduled", "retryable"] and j.scheduled_at <= ^now)
    )
  end

  defp due_by_queue(repo, now, qopts) do
    due_query(now)
    |> group_by([j], j.queue)
    |> select([j], %{
      queue: j.queue,
      count: count(j.id),
      oldest: type(min(j.scheduled_at), :utc_datetime_usec)
    })
    |> repo.all(qopts)
  end

  # -- failure patterns: retry storms, discard and cancel spikes ----------------------------

  def retry_storm(repo, cfg, now, qopts) do
    window = cfg[:retry_storm][:window]
    min = cfg[:retry_storm][:min_retries]
    cutoff = DateTime.add(now, -window, :second)

    base =
      from(j in Job,
        where: j.state == "retryable" or (j.attempt >= 2 and j.attempted_at >= ^cutoff)
      )

    per_worker(repo, base, qopts, min, fn worker, count ->
      {:retry_storm, count, min,
       "Retry storm in #{worker}: #{count} retrying/retried job(s) in the last #{window}s (limit #{min})."}
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

    per_worker(repo, base, qopts, max, fn worker, count ->
      {check, count, max,
       "#{count} #{worker} job(s) #{verb} in the last #{window}s (limit #{max}). These fail silently unless something alerts on them."}
    end)
  end

  # -- missing insertions (cron jobs that silently stopped) ------------------------------
  # Opt-in: `expected` maps worker name => max seconds between insertions. Looks at the newest
  # row for each worker in any state, so the Pruner's `max_age` must exceed the largest gap.

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

  defp per_worker(repo, base, qopts, threshold, describe) do
    rows =
      base
      |> group_by([j], [j.worker, j.queue])
      |> select([j], {j.worker, j.queue, count(j.id)})
      |> repo.all(qopts)

    rows
    |> Enum.group_by(fn {w, _, _} -> w end)
    |> Enum.flat_map(fn {worker, list} ->
      count = list |> Enum.map(&elem(&1, 2)) |> Enum.sum()

      if count >= threshold do
        {check, value, limit, message} = describe.(worker, count)
        queues = list |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.join(",")

        [
          %Finding{
            check: check,
            severity: severity(value, limit),
            queue: queues,
            worker: worker,
            count: count,
            value: value,
            threshold: limit,
            message: message,
            job_ids: sample_ids(repo, base |> where([j], j.worker == ^worker), qopts)
          }
        ]
      else
        []
      end
    end)
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp group_findings(jobs, check, describe) do
    jobs
    |> Enum.group_by(&{&1.queue, &1.worker})
    |> Enum.map(fn {{queue, worker}, group} ->
      {severity, value, threshold, message} = describe.(group)

      %Finding{
        check: check,
        severity: severity,
        queue: queue,
        worker: worker,
        count: length(group),
        value: value,
        threshold: threshold,
        message: message,
        job_ids: group |> Enum.map(& &1.id) |> Enum.sort() |> Enum.take(@sample)
      }
    end)
  end

  defp sample_ids(repo, query, qopts) do
    query |> select([j], j.id) |> order_by([j], asc: j.id) |> limit(@sample) |> repo.all(qopts)
  end

  defp age(nil, _now), do: 0
  defp age(%NaiveDateTime{} = t, now), do: age(DateTime.from_naive!(t, "Etc/UTC"), now)
  defp age(%DateTime{} = t, now), do: max(DateTime.diff(now, t, :second), 0)

  defp severity(value, threshold) when value >= 2 * threshold, do: :critical
  defp severity(_value, _threshold), do: :warning
end
