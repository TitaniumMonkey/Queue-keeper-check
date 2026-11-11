# Comparable seven-default-check warm benchmark (orphaned, hanging, backlog,
# stalled, retry_storm, discarded, cancelled). Not the 10M-row / combined-check
# / scan workload.
#
#   MIX_ENV=test mix run --no-start bench/seven_pg.exs [rows ...]
#     default sizes: 10000 250000 1000000
#
# Connection: QK_PERF_URL (default ecto://postgres:postgres@localhost/qk_seven).
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

defmodule Bench.Seven.Repo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule Bench.Seven.Migration do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
end

url = System.get_env("QK_PERF_URL", "ecto://postgres:postgres@localhost/qk_seven")

sizes =
  case System.argv() do
    [] -> [10_000, 250_000, 1_000_000]
    args -> Enum.map(args, &String.to_integer/1)
  end

cfg = Ecto.Repo.Supervisor.parse_url(url) ++ [pool_size: 2, timeout: :infinity, log: false]
Application.put_env(:queue_keeper_check, Bench.Seven.Repo, cfg)

mix = [
  {"completed", 0.90},
  {"available", 0.04},
  {"discarded", 0.03},
  {"cancelled", 0.02},
  {"scheduled", 0.008},
  {"retryable", 0.001},
  {"executing", 0.001}
]

only = [:orphaned, :hanging, :backlog, :stalled, :retry_storm, :discarded, :cancelled]

seed = fn rows ->
  _ = Ecto.Adapters.Postgres.storage_down(cfg)
  :ok = Ecto.Adapters.Postgres.storage_up(cfg)
  {:ok, _} = Bench.Seven.Repo.start_link(cfg)
  Ecto.Migrator.up(Bench.Seven.Repo, 1, Bench.Seven.Migration, log: false)

  {chunks, _used} =
    Enum.map_reduce(Enum.with_index(mix), 0, fn {{state, share}, i}, used ->
      n = if i == length(mix) - 1, do: rows - used, else: max(round(rows * share), 0)
      n = min(n, max(rows - used, 0))
      {{state, n}, used + n}
    end)

  Enum.reduce(chunks, 1, fn {state, n}, from ->
    to = from + n - 1

    if n > 0 do
      sql = """
      INSERT INTO public.oban_jobs
        (state, queue, worker, args, errors, attempt, max_attempts, priority, tags, meta,
         inserted_at, scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at, attempted_by)
      SELECT
        '#{state}'::oban_job_state,
        'queue_' || (g % 20),
        'MyApp.Workers.W' || (g % 1000),
        jsonb_build_object('email', 'user' || g || '@example.com', 'ssn', '000-00-0000'),
        CASE WHEN '#{state}' IN ('discarded', 'retryable', 'cancelled')
             THEN ARRAY[jsonb_build_object('attempt', 1, 'at', now(), 'error', 'failed')]
             ELSE ARRAY[]::jsonb[] END,
        CASE WHEN '#{state}' IN ('retryable', 'discarded') THEN 2 ELSE 1 END,
        20, g % 4, ARRAY[]::text[], '{}'::jsonb,
        now() - interval '600 seconds' - (g % 60) * interval '1 second',
        CASE '#{state}'
          WHEN 'available' THEN now() - interval '600 seconds'
          WHEN 'scheduled' THEN now() + interval '600 seconds'
          WHEN 'retryable' THEN now() - interval '600 seconds'
          ELSE now() - interval '600 seconds'
        END,
        CASE WHEN '#{state}' IN ('available', 'scheduled') THEN NULL
             ELSE now() - interval '100 seconds' - (g % 10) * interval '1 second' END,
        CASE WHEN '#{state}' = 'completed' THEN now() - interval '90 seconds' END,
        CASE WHEN '#{state}' = 'discarded' THEN now() - interval '90 seconds' END,
        CASE WHEN '#{state}' = 'cancelled' THEN now() - interval '90 seconds' END,
        CASE WHEN '#{state}' IN ('available', 'scheduled') THEN ARRAY[]::text[]
             ELSE ARRAY['node-1'] END
      FROM generate_series(#{from}, #{to}) AS g
      """

      Bench.Seven.Repo.query!(sql, [], timeout: :infinity)
    end

    from + n
  end)

  Bench.Seven.Repo.query!("ANALYZE public.oban_jobs", [], timeout: :infinity)

  checksum =
    Bench.Seven.Repo.query!(
      "SELECT count(*), coalesce(sum(id),0), coalesce(sum(attempt),0) FROM public.oban_jobs",
      []
    ).rows
    |> hd()

  {chunks, checksum}
end

percentile = fn sorted, p ->
  i = max(round(p / 100 * length(sorted)) - 1, 0)
  Enum.at(sorted, i)
end

handler_id = "qk-seven-bench"

for rows <- sizes do
  IO.puts("\n== seeding #{rows} rows ==")
  {chunks, checksum} = seed.(rows)
  IO.puts("state mix: #{inspect(chunks)}")
  IO.puts("checksum count/sum(id)/sum(attempt): #{inspect(checksum)}")

  events = :counters.new(1, [:atomics])

  :ok =
    :telemetry.attach(
      handler_id,
      [:ecto, :repo, :query],
      fn _e, _m, _meta, _ -> :counters.add(events, 1, 1) end,
      nil
    )

  run = fn ->
    :counters.put(events, 1, 0)
    {us, report} = :timer.tc(fn -> QueueKeeperCheck.run(Bench.Seven.Repo, only: only) end)
    {us / 1000, report, :counters.get(events, 1)}
  end

  {warm_ms, warm_report, warm_ev} = run.()
  IO.puts("warmup: #{Float.round(warm_ms, 2)} ms, #{warm_ev} SQL events, errors=#{inspect(warm_report.errors)}")

  {times, evs, errors} =
    Enum.reduce(1..10, {[], [], []}, fn _, {ts, es, errs} ->
      {ms, report, ev} = run.()
      {ts ++ [ms], es ++ [ev], errs ++ report.errors}
    end)

  :telemetry.detach(handler_id)

  sorted = Enum.sort(times)
  med = Enum.at(sorted, div(length(sorted), 2))
  p95 = percentile.(sorted, 95)
  maxv = List.last(sorted)
  ev_med = evs |> Enum.sort() |> Enum.at(div(length(evs), 2))

  checksum2 =
    Bench.Seven.Repo.query!(
      "SELECT count(*), coalesce(sum(id),0), coalesce(sum(attempt),0) FROM public.oban_jobs",
      []
    ).rows
    |> hd()

  Supervisor.stop(Process.whereis(Bench.Seven.Repo))

  IO.puts(
    "#{rows} rows: median #{Float.round(med, 2)} ms  p95 #{Float.round(p95, 2)} ms  max #{Float.round(maxv, 2)} ms  " <>
      "SQL events median #{ev_med}  check errors #{length(errors)}"
  )

  IO.puts("checksum after runs: #{inspect(checksum2)} unchanged?=#{checksum == checksum2}")
end
