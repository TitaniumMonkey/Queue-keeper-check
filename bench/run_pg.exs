# Times every check against the `qk_perf` database built by bench/setup_pg.exs and prints
# EXPLAIN (ANALYZE, BUFFERS) for every distinct SQL statement the library issued.
#
#   MIX_ENV=test mix run --no-start bench/run_pg.exs [out_dir]   # default bench/results
#
# Uses the library's default thresholds plus a :cron_missing config with one frequent worker
# and one worker that never ran (the worst case: nothing to find, so the whole table is a
# candidate). Statement timeouts are lifted for the measurement so slow plans show up as slow.
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

defmodule Bench.Repo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

url = System.get_env("QK_PERF_URL", "ecto://postgres:postgres@localhost/qk_perf")
out = List.first(System.argv()) || "bench/results"
File.mkdir_p!(out)

cfg = Ecto.Repo.Supervisor.parse_url(url) ++ [pool_size: 2, timeout: :infinity, log: false]
Application.put_env(:queue_keeper_check, Bench.Repo, cfg)
{:ok, _} = Bench.Repo.start_link(cfg)

{:ok, agent} = Agent.start_link(fn -> [] end)

defmodule Bench.Handler do
  def handle(_event, m, meta, agent) do
    Agent.update(agent, &[{meta.query, meta.cast_params || meta.params, m.total_time} | &1])
  end
end

:telemetry.attach("bench", [:bench, :repo, :query], &Bench.Handler.handle/4, agent)

base = [
  cron_missing: [expected: %{"MyApp.Workers.W7" => 3_900, "MyApp.Workers.Never" => 90_000}]
]

# Lift the library's own timeouts (if this version has them) so we measure real cost.
guard_opts =
  if Code.ensure_loaded?(QueueKeeperCheck.Config) and function_exported?(QueueKeeperCheck.Config, :guard_defaults, 0),
    do: [statement_timeout: 600_000, lock_timeout: 1_000],
    else: []

opts = base ++ guard_opts

time = fn fun ->
  t = System.monotonic_time(:microsecond)
  r = fun.()
  {(System.monotonic_time(:microsecond) - t) / 1000, r}
end

median = fn xs -> xs |> Enum.sort() |> Enum.at(div(length(xs), 2)) end

%{rows: [[count, size]]} =
  Bench.Repo.query!(
    "SELECT count(*), pg_size_pretty(pg_total_relation_size('public.oban_jobs')) FROM public.oban_jobs"
  )

%{rows: [[pgv]]} = Bench.Repo.query!("SHOW server_version")
%{rows: [[sb]]} = Bench.Repo.query!("SHOW shared_buffers")
%{rows: states} = Bench.Repo.query!("SELECT state::text, count(*) FROM public.oban_jobs GROUP BY 1 ORDER BY 2 DESC")

header = """
rows=#{count} size=#{size} postgres=#{pgv} shared_buffers=#{sb} cpus=#{System.schedulers_online()}
states=#{inspect(states)}
"""

IO.puts(header)

# Warm-up full run, then REPS (default 3) timed runs per check.
reps = String.to_integer(System.get_env("REPS", "3"))
_ = QueueKeeperCheck.run(Bench.Repo, opts)

per_check =
  for check <- QueueKeeperCheck.checks() do
    runs = for _ <- 1..reps, do: elem(time.(fn -> QueueKeeperCheck.run(Bench.Repo, [only: [check]] ++ opts) end), 0)
    {check, median.(runs)}
  end

Agent.update(agent, fn _ -> [] end)
{total_ms, report} = time.(fn -> QueueKeeperCheck.run(Bench.Repo, opts) end)
statements = agent |> Agent.get(& &1) |> Enum.reverse()

lines =
  for {check, ms} <- per_check, do: "#{check}\t#{:erlang.float_to_binary(ms, decimals: 1)} ms"

# Once more with the library's default safety limits (5 s statement_timeout etc.).
{default_ms, default_report} = time.(fn -> QueueKeeperCheck.run(Bench.Repo, base) end)
default_errors = Map.get(default_report, :errors, [])

summary = """
#{header}
full run: #{:erlang.float_to_binary(total_ms, decimals: 1)} ms, #{length(statements)} statements, status=#{report.status}, findings=#{length(report.findings)}
full run with default limits: #{:erlang.float_to_binary(default_ms, decimals: 1)} ms, status=#{default_report.status}, errors=#{length(default_errors)}
per check (median of #{reps}, warm):
#{Enum.join(lines, "\n")}
"""

IO.puts(summary)

explains =
  statements
  |> Enum.uniq_by(fn {q, _, _} -> q end)
  |> Enum.filter(fn {q, _, _} -> q =~ ~r/^SELECT/i and q =~ ~s("oban_jobs" AS o0) end)
  |> Enum.with_index(1)
  |> Enum.map(fn {{q, params, _}, i} ->
    %{rows: plan} = Bench.Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> q, params, timeout: :infinity)
    plan = Enum.map_join(plan, "\n", &hd/1)
    exec = Regex.run(~r/Execution Time: ([\d.]+) ms/, plan) |> List.last()
    seq = if plan =~ "Seq Scan", do: "SEQ SCAN", else: "no seq scan"
    IO.puts("Q#{i}\t#{exec} ms\t#{seq}\t#{String.slice(q, 0, 110)}")
    "-- Q#{i} (#{exec} ms, #{seq})\n#{q}\n-- params: #{inspect(params)}\n#{plan}\n"
  end)

File.write!(Path.join(out, "pg_summary.txt"), summary)
File.write!(Path.join(out, "pg_explain.txt"), Enum.join(explains, "\n"))
IO.puts("wrote #{out}/pg_summary.txt and #{out}/pg_explain.txt")
