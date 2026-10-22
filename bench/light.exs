# Lighter performance run for MySQL (Dolphin) and SQLite (Lite): builds a fresh database
# with Oban's standard schema, seeds synthetic rows (same state mix as setup_pg.exs), times
# each check and prints the engine's plan for every distinct statement.
#
#   MIX_ENV=test mix run --no-start bench/light.exs mysql  [rows]   # default 1_000_000
#   MIX_ENV=test mix run --no-start bench/light.exs sqlite [rows]
#
# MySQL: 127.0.0.1:3307 root (dev/mysql84.sh), database qk_perf. SQLite: tmp/qk_perf.sqlite3.
[engine | rest] = System.argv()
rows = String.to_integer(List.first(rest) || "1000000")
Application.ensure_all_started(:ecto_sql)

{adapter, app, cfg} =
  case engine do
    "mysql" ->
      {Ecto.Adapters.MyXQL, :myxql,
       [
         hostname: "127.0.0.1",
         port: 3307,
         username: "root",
         password: "",
         database: "qk_perf",
         after_connect: &MyXQL.query!(&1, "SET SESSION cte_max_recursion_depth = 1000000", [])
       ]}

    "sqlite" ->
      {Ecto.Adapters.SQLite3, :ecto_sqlite3, [database: Path.expand("tmp/qk_perf.sqlite3")]}
  end

Application.ensure_all_started(app)

defmodule Bench.Light.Migration do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
end

repo_mod =
  Module.concat(Bench.Light, String.capitalize(engine) <> "Repo")

Module.create(
  repo_mod,
  quote do
    use Ecto.Repo, otp_app: :queue_keeper_check, adapter: unquote(adapter)
  end,
  Macro.Env.location(__ENV__)
)

cfg = cfg ++ [pool_size: 2, timeout: :infinity, log: false]
_ = adapter.storage_down(cfg)
:ok = adapter.storage_up(cfg)
{:ok, _} = repo_mod.start_link(cfg)
Ecto.Migrator.up(repo_mod, 1, Bench.Light.Migration, log: false)

mix = [
  {"completed", 0.9},
  {"discarded", 0.03},
  {"cancelled", 0.02},
  {"available", 0.04},
  {"scheduled", 0.008},
  {"retryable", 0.0019},
  {"executing", 0.0001}
]

batch = 100_000
started = System.monotonic_time(:millisecond)

# Expression helpers per engine: t = job time, `secs` seconds before now / after now.
{ts, gen} =
  case engine do
    "mysql" ->

      {fn secs -> "TIMESTAMPADD(SECOND, -(#{secs}), UTC_TIMESTAMP(6))" end,
       fn from, to, select ->
         "INSERT INTO oban_jobs (state, queue, worker, args, errors, attempt, max_attempts, priority, inserted_at, scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at) " <>
           "WITH RECURSIVE s(g) AS (SELECT #{from} UNION ALL SELECT g + 1 FROM s WHERE g < #{to}) " <>
           select <> " FROM s"
       end}

    "sqlite" ->
      {fn secs -> "strftime('%Y-%m-%dT%H:%M:%SZ', 'now', printf('%d seconds', -(#{secs})))" end,
       fn from, to, select ->
         "WITH RECURSIVE s(g) AS (SELECT #{from} UNION ALL SELECT g + 1 FROM s WHERE g < #{to}) " <>
           "INSERT INTO oban_jobs (state, queue, worker, args, errors, attempt, max_attempts, priority, inserted_at, scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at) " <>
           select <> " FROM s"
       end}
  end

concat = fn a, b -> if engine == "mysql", do: "CONCAT(#{a}, #{b})", else: "(#{a} || #{b})" end

for {state, share} <- mix, reduce: 0 do
  offset ->
    n = max(round(rows * share), 1)
    age = "((g * 7919) % 2592000)"
    queue_mod = if state == "available", do: 8, else: 40

    sched =
      case state do
        "available" -> ts.("g % 7200")
        "scheduled" -> ts.("-(((g % 100) - 5) * 60)")
        "retryable" -> ts.("-(((g % 60) - 10) * 60)")
        _ -> ts.(age)
      end

    attempted =
      case state do
        s when s in ["available", "scheduled"] -> "NULL"
        "executing" -> ts.("CASE WHEN g % 10 = 0 THEN 7200 ELSE g % 120 END")
        _ -> ts.("#{age} - 1")
      end

    fin = fn st -> if state == st, do: ts.("#{age} - 3"), else: "NULL" end

    select =
      "SELECT '#{state}', #{concat.("'queue_'", "(g % #{queue_mod})")}, #{concat.("'MyApp.Workers.W'", "(g % 250)")}, " <>
        "'{\"email\":\"user@example.com\"}', '[]', " <>
        "CASE WHEN g % 20 = 0 OR '#{state}' IN ('retryable', 'discarded') THEN 2 + g % 2 ELSE 1 END, 20, g % 4, " <>
        "#{ts.("#{age} + 2")}, #{sched}, #{attempted}, #{fin.("completed")}, #{fin.("discarded")}, #{fin.("cancelled")}"

    for from <- offset..(offset + n - 1)//batch do
      to = min(from + batch - 1, offset + n - 1)
      repo_mod.query!(gen.(from, to, select), [], timeout: :infinity)
    end

    offset + n
end

if engine == "mysql", do: repo_mod.query!("ANALYZE TABLE oban_jobs"), else: repo_mod.query!("ANALYZE")
%{rows: [[count]]} = repo_mod.query!("SELECT count(*) FROM oban_jobs")
seed_s = div(System.monotonic_time(:millisecond) - started, 1000)

%{rows: [[version]]} =
  repo_mod.query!(if engine == "mysql", do: "SELECT version()", else: "SELECT sqlite_version()")

{:ok, agent} = Agent.start_link(fn -> [] end)
prefix = repo_mod.config()[:telemetry_prefix] ++ [:query]

:telemetry.attach("light", prefix, fn _, _, m, _ -> Agent.update(agent, &[{m.query, m.cast_params || m.params} | &1]) end, nil)

opts = [cron_missing: [expected: %{"MyApp.Workers.W7" => 3_900, "MyApp.Workers.Never" => 90_000}], statement_timeout: 600_000]
_ = QueueKeeperCheck.run(repo_mod, opts)

per_check =
  for check <- QueueKeeperCheck.checks() do
    runs =
      for _ <- 1..3 do
        {us, _} = :timer.tc(fn -> QueueKeeperCheck.run(repo_mod, [only: [check]] ++ opts) end)
        us / 1000
      end

    {check, runs |> Enum.sort() |> Enum.at(1)}
  end

Agent.update(agent, fn _ -> [] end)
{full_us, report} = :timer.tc(fn -> QueueKeeperCheck.run(repo_mod, opts) end)
statements = agent |> Agent.get(& &1) |> Enum.reverse()

summary = """
engine=#{engine} version=#{version} rows=#{count} seeded_in=#{seed_s}s cpus=#{System.schedulers_online()}
full run: #{Float.round(full_us / 1000, 1)} ms, #{length(statements)} statements, status=#{report.status}, findings=#{length(report.findings)}, errors=#{length(report.errors)}
per check (median of 3, warm):
#{Enum.map_join(per_check, "\n", fn {c, ms} -> "#{c}\t#{Float.round(ms, 1)} ms" end)}
"""

IO.puts(summary)

plans =
  statements
  |> Enum.uniq_by(&elem(&1, 0))
  |> Enum.filter(fn {q, _} -> q =~ ~r/^SELECT/i and q =~ "oban_jobs" end)
  |> Enum.with_index(1)
  |> Enum.map(fn {{q, params}, i} ->
    explain = if engine == "mysql", do: "EXPLAIN ANALYZE ", else: "EXPLAIN QUERY PLAN "
    %{rows: plan} = repo_mod.query!(explain <> q, params, timeout: :infinity)
    plan = Enum.map_join(plan, "\n", fn row -> row |> Enum.map(&to_string/1) |> Enum.join(" ") end)
    full_scan = plan =~ ~r/Table scan on o\d+|\bSCAN (o\d+|oban_jobs)\b(?! USING)/
    IO.puts("Q#{i}\t#{if full_scan, do: "FULL SCAN", else: "index"}\t#{String.slice(q, 0, 110)}")
    "-- Q#{i}#{if full_scan, do: " (FULL SCAN)", else: ""}\n#{q}\n-- params: #{inspect(params)}\n#{plan}\n"
  end)

File.mkdir_p!("bench/results")
File.write!("bench/results/#{engine}_summary.txt", summary)
File.write!("bench/results/#{engine}_explain.txt", Enum.join(plans, "\n"))
