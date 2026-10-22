# Creates the `qk_perf` database with Oban's standard schema (all Postgres migrations, no
# extra indexes) and seeds a synthetic oban_jobs table. Run from the repo root:
#
#   MIX_ENV=test mix run --no-start bench/setup_pg.exs [rows]   # default 10_000_000
#
# Connection: QK_PERF_URL (default ecto://postgres:postgres@localhost/qk_perf).
# Args/errors contain *fake* PII-looking strings so you can verify the check never reads them.
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

defmodule Bench.Repo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule Bench.Migration do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
end

url = System.get_env("QK_PERF_URL", "ecto://postgres:postgres@localhost/qk_perf")
rows = String.to_integer(List.first(System.argv()) || "10000000")
cfg = Ecto.Repo.Supervisor.parse_url(url) ++ [pool_size: 2, timeout: :infinity, log: false]
Application.put_env(:queue_keeper_check, Bench.Repo, cfg)

_ = Ecto.Adapters.Postgres.storage_down(cfg)
:ok = Ecto.Adapters.Postgres.storage_up(cfg)
{:ok, _} = Bench.Repo.start_link(cfg)
Ecto.Migrator.up(Bench.Repo, 1, Bench.Migration, log: false)

# Share of rows per state. Times are relative to the seeding moment (now()).
#   completed : 30-day history (the Pruner is assumed to keep 30 days), 5% retried (attempt 2-3)
#   discarded / cancelled : 30-day history, errors carry fake PII
#   available : backlog across 8 queues, due within the last 2 hours
#   scheduled : mostly future, a few overdue;  retryable: future and overdue
#   executing : running now, plus some orphans (hours old)
mix = [
  {"completed", 0.9},
  {"discarded", 0.03},
  {"cancelled", 0.02},
  {"available", 0.04},
  {"scheduled", 0.008},
  {"retryable", 0.0019},
  {"executing", 0.0001}
]

batch = 500_000

sql = fn state, from, to ->
  """
  INSERT INTO public.oban_jobs
    (state, queue, worker, args, errors, attempt, max_attempts, priority, tags, meta,
     inserted_at, scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at, attempted_by)
  SELECT
    '#{state}'::oban_job_state,
    CASE WHEN '#{state}' = 'available' THEN 'queue_' || (g % 8) ELSE 'queue_' || (g % 40) END,
    'MyApp.Workers.W' || (g % 250),
    jsonb_build_object('email', 'user' || g || '@example.com', 'ssn', '000-00-' || lpad((g % 10000)::text, 4, '0'), 'note', md5(g::text)),
    CASE WHEN '#{state}' IN ('discarded', 'retryable', 'cancelled')
         THEN ARRAY[jsonb_build_object('attempt', 1, 'at', now(), 'error', '** (RuntimeError) failed for user' || g || '@example.com')]
         ELSE ARRAY[]::jsonb[] END,
    CASE WHEN g % 20 = 0 OR '#{state}' IN ('retryable', 'discarded') THEN 2 + g % 2 ELSE 1 END,
    20, g % 4, ARRAY[]::text[], '{}'::jsonb,
    t - interval '2 seconds',
    CASE '#{state}'
      WHEN 'available' THEN now() - (g % 7200) * interval '1 second'
      WHEN 'scheduled' THEN now() + ((g % 100) - 5) * interval '1 minute'
      WHEN 'retryable' THEN now() + ((g % 60) - 10) * interval '1 minute'
      ELSE t END,
    CASE WHEN '#{state}' IN ('available', 'scheduled') THEN NULL
         WHEN '#{state}' = 'executing' THEN now() - (CASE WHEN g % 10 = 0 THEN 7200 ELSE g % 120 END) * interval '1 second'
         ELSE t + interval '1 second' END,
    CASE WHEN '#{state}' = 'completed' THEN t + interval '3 seconds' END,
    CASE WHEN '#{state}' = 'discarded' THEN t + interval '3 seconds' END,
    CASE WHEN '#{state}' = 'cancelled' THEN t + interval '3 seconds' END,
    CASE WHEN '#{state}' IN ('available', 'scheduled') THEN ARRAY[]::text[] ELSE ARRAY['node-' || (g % 6), 'uuid'] END
  FROM generate_series(#{from}, #{to}) AS g,
       LATERAL (SELECT now() - ((g::bigint * 7919) % 2592000) * interval '1 second' AS t) ts
  """
end

started = System.monotonic_time(:millisecond)

Enum.reduce(mix, 0, fn {state, share}, offset ->
  n = max(round(rows * share), 1)

  for from <- offset..(offset + n - 1)//batch do
    to = min(from + batch - 1, offset + n - 1)
    Bench.Repo.query!(sql.(state, from, to))
    IO.puts("#{state}: #{to - offset + 1}/#{n}")
  end

  offset + n
end)

Bench.Repo.query!("VACUUM ANALYZE public.oban_jobs")
%{rows: [[count, size]]} =
  Bench.Repo.query!("SELECT count(*), pg_size_pretty(pg_total_relation_size('public.oban_jobs')) FROM public.oban_jobs")

IO.puts("seeded #{count} rows (#{size} incl. indexes) in #{div(System.monotonic_time(:millisecond) - started, 1000)}s")
