defmodule QueueKeeperCheck.SharedCases do
  @moduledoc """
  The unit scenarios, shared by the Postgres (Basic engine), SQLite (Lite engine) and
  MySQL (Dolphin engine, opt-in with QK_MYSQL=1) suites.
  Each scenario writes `oban_jobs` rows exactly as Oban leaves them in that failure mode,
  then asserts the matching check fires (and that healthy data stays quiet).
  """
  defmacro __using__(repo: repo, adapter: adapter) do
    quote do
      alias QueueKeeperCheck.{Finding, Report}
      @repo unquote(repo)
      @adapter unquote(adapter)

      @now ~U[2026-10-22 12:00:00.000000Z]

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
      end

      test "adapter sanity" do
        assert @repo.__adapter__() == @adapter
      end

      defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

      defp insert(attrs) do
        defaults = %{
          state: "completed",
          queue: "default",
          worker: "Demo.Worker",
          args: %{},
          attempt: 1,
          max_attempts: 20,
          inserted_at: ago(10),
          scheduled_at: ago(10),
          attempted_at: ago(9),
          completed_at: ago(8)
        }

        attrs = Map.merge(defaults, Map.new(attrs))
        @repo.insert!(struct(Oban.Job, attrs))
      end

      defp insert_many(n, attrs), do: for(_ <- 1..n, do: insert(attrs))

      defp run(opts \\ []), do: QueueKeeperCheck.run(@repo, Keyword.put_new(opts, :now, @now))

      defp only(report, check), do: Enum.filter(report.findings, &(&1.check == check))

      test "healthy queues produce no findings" do
        insert_many(50, %{})
        insert_many(3, state: "executing", attempted_at: ago(5), completed_at: nil)

        insert_many(5,
          state: "available",
          scheduled_at: ago(2),
          attempted_at: nil,
          completed_at: nil
        )

        insert_many(2,
          state: "retryable",
          attempt: 2,
          scheduled_at: DateTime.add(@now, 30),
          completed_at: nil
        )

        insert(state: "discarded", discarded_at: ago(60), completed_at: nil)

        assert %Report{status: :ok, findings: []} = run()
        assert QueueKeeperCheck.format(run()) =~ "OK: no Oban queue problems"
      end

      test "orphaned: executing for longer than the orphan limit is critical, and not also reported as hanging" do
        %{id: id} =
          insert(
            state: "executing",
            worker: "Demo.Import",
            attempted_at: ago(4000),
            completed_at: nil
          )

        insert(
          state: "executing",
          worker: "Demo.Import",
          attempted_at: ago(10),
          completed_at: nil
        )

        report = run()

        assert [
                 %Finding{
                   check: :orphaned,
                   severity: :critical,
                   count: 1,
                   job_ids: [^id],
                   worker: "Demo.Import"
                 }
               ] =
                 only(report, :orphaned)

        assert only(report, :hanging) == []
        assert report.status == :critical

        # the message says what is measured (age), not that the node is known to be dead
        assert [%Finding{message: message}] = only(report, :orphaned)
        assert message =~ "far beyond any expected runtime; possibly orphaned by a node crash"
        assert message =~ "measures execution age only"
      end

      test "hanging: per-worker budgets override the default budget" do
        insert(state: "executing", worker: "Demo.Email", attempted_at: ago(90), completed_at: nil)
        insert(state: "executing", worker: "Demo.Video", attempted_at: ago(90), completed_at: nil)

        report = run(hanging: [default_budget: 60, budgets: %{"Demo.Video" => 1800}])

        assert [
                 %Finding{
                   check: :hanging,
                   worker: "Demo.Email",
                   value: 90,
                   threshold: 60,
                   severity: :warning
                 }
               ] =
                 only(report, :hanging)
      end

      test "backlog: depth over the limit" do
        insert_many(12,
          state: "available",
          queue: "mailers",
          scheduled_at: ago(5),
          attempted_at: nil,
          completed_at: nil
        )

        insert(
          state: "completed",
          queue: "mailers",
          scheduled_at: ago(5),
          attempted_at: ago(1),
          completed_at: ago(1)
        )

        assert [%Finding{check: :backlog, queue: "mailers", count: 12, value: 12, threshold: 10}] =
                 only(run(backlog: [max_depth: 10]), :backlog)
      end

      test "backlog: latency counts overdue scheduled and retryable jobs, not future ones" do
        insert(
          state: "scheduled",
          queue: "billing",
          scheduled_at: ago(400),
          attempted_at: nil,
          completed_at: nil
        )

        insert(
          state: "retryable",
          queue: "billing",
          attempt: 2,
          scheduled_at: ago(350),
          completed_at: nil
        )

        insert(
          state: "scheduled",
          queue: "billing",
          scheduled_at: DateTime.add(@now, 3600),
          attempted_at: nil,
          completed_at: nil
        )

        assert [
                 %Finding{
                   check: :backlog,
                   queue: "billing",
                   count: 2,
                   value: 400,
                   threshold: 300,
                   severity: :warning
                 }
               ] =
                 only(run(), :backlog)
      end

      test "stalled: due jobs waiting with no recent activity in the queue" do
        insert_many(3,
          state: "available",
          queue: "ghost",
          scheduled_at: ago(900),
          attempted_at: nil,
          completed_at: nil
        )

        # busy queue with the same latency but recent attempts is backed up, not stalled
        insert_many(3,
          state: "available",
          queue: "busy",
          scheduled_at: ago(900),
          attempted_at: nil,
          completed_at: nil
        )

        insert(queue: "busy", attempted_at: ago(5), completed_at: ago(4))

        report = run()

        assert [%Finding{check: :stalled, queue: "ghost", severity: :critical, count: 3}] =
                 only(report, :stalled)

        assert report |> only(:backlog) |> Enum.map(& &1.queue) |> Enum.sort() == [
                 "busy",
                 "ghost"
               ]
      end

      test "stalled: a queue whose only executing jobs started long ago is also reported" do
        # Documented limitation: every slot busy with one long job (attempted 10 min ago) and
        # work waiting looks the same as a stopped queue, because nothing was attempted in the
        # window.
        insert(state: "executing", queue: "slow", attempted_at: ago(600), completed_at: nil)

        insert_many(3,
          state: "available",
          queue: "slow",
          scheduled_at: ago(400),
          attempted_at: nil,
          completed_at: nil
        )

        assert [%Finding{check: :stalled, queue: "slow"}] = only(run(), :stalled)
      end

      test "stalled: recent discards or completions count as activity, within the lookback" do
        for q <- ["discards", "completes", "ancient"] do
          insert_many(2,
            state: "available",
            queue: q,
            scheduled_at: ago(900),
            attempted_at: nil,
            completed_at: nil
          )
        end

        insert(
          queue: "discards",
          state: "discarded",
          discarded_at: ago(5),
          attempted_at: ago(6),
          completed_at: nil
        )

        insert(
          queue: "completes",
          scheduled_at: ago(3_000),
          attempted_at: ago(5),
          completed_at: ago(4)
        )

        # attempted recently, but it had been scheduled 2 days ago: outside the default lookback
        insert(
          queue: "ancient",
          scheduled_at: ago(172_800),
          attempted_at: ago(5),
          completed_at: ago(4)
        )

        assert ["ancient"] = run() |> only(:stalled) |> Enum.map(& &1.queue)
        assert [] = run(stalled: [lookback: 200_000]) |> only(:stalled)
      end

      test "sample ids are capped per run, findings are not" do
        for w <- 1..105 do
          insert(
            state: "cancelled",
            worker: "Demo.W#{w}",
            cancelled_at: ago(60),
            completed_at: nil
          )
        end

        findings = only(run(cancelled: [max: 1]), :cancelled)
        assert length(findings) == 105
        assert Enum.count(findings, &(&1.job_ids != [])) == 100
      end

      test "retry storm: many retrying jobs for one worker in the window" do
        insert_many(15,
          state: "retryable",
          worker: "Demo.Flaky",
          attempt: 3,
          attempted_at: ago(20),
          scheduled_at: DateTime.add(@now, 10),
          completed_at: nil
        )

        insert_many(10,
          state: "completed",
          worker: "Demo.Flaky",
          attempt: 4,
          attempted_at: ago(30)
        )

        # old retries fall outside the window
        insert_many(30,
          state: "completed",
          worker: "Demo.Old",
          attempt: 2,
          attempted_at: ago(4000)
        )

        # default: retrying now (15) only; completed retries need include_completed (full scan)
        assert [] = only(run(), :retry_storm)

        assert [%Finding{check: :retry_storm, worker: "Demo.Flaky", count: 15, threshold: 10}] =
                 only(run(retry_storm: [min_retries: 10]), :retry_storm)

        assert [
                 %Finding{
                   check: :retry_storm,
                   worker: "Demo.Flaky",
                   count: 25,
                   threshold: 20,
                   severity: :warning
                 }
               ] =
                 only(run(retry_storm: [include_completed: true]), :retry_storm)
      end

      test "retry storm: retryable jobs count only when their failed attempt is in the window" do
        # failed 20s ago, retry due in 10s: inside the default 300s window
        insert_many(6,
          state: "retryable",
          worker: "Demo.Win",
          attempt: 2,
          attempted_at: ago(20),
          scheduled_at: DateTime.add(@now, 10),
          completed_at: nil
        )

        # failed 4000s ago and still waiting out a long backoff (retry due in 1h): outside
        insert_many(7,
          state: "retryable",
          worker: "Demo.Win",
          attempt: 5,
          attempted_at: ago(4000),
          scheduled_at: DateTime.add(@now, 3600),
          completed_at: nil
        )

        # failed 4000s ago, retry overdue (scheduled 3990s ago, queue backed up): outside
        insert_many(8,
          state: "retryable",
          worker: "Demo.Win",
          attempt: 3,
          attempted_at: ago(4000),
          scheduled_at: ago(3990),
          completed_at: nil
        )

        assert [%Finding{worker: "Demo.Win", count: 6, job_ids: ids}] =
                 only(run(retry_storm: [min_retries: 5]), :retry_storm)

        assert length(ids) == 6

        # a 10s window excludes the jobs that failed 20s ago too
        assert [] = only(run(retry_storm: [min_retries: 1, window: 10]), :retry_storm)

        # a window long enough to reach back 4000s counts all 21
        assert [%Finding{worker: "Demo.Win", count: 21, severity: :critical}] =
                 only(run(retry_storm: [min_retries: 10, window: 4001]), :retry_storm)

        assert [%Finding{message: message}] =
                 only(run(retry_storm: [min_retries: 5]), :retry_storm)

        assert message =~ "in the last 300s"
      end

      test "retry storm: retried jobs that were discarded, cancelled or are executing count" do
        insert_many(3,
          state: "executing",
          worker: "Demo.R",
          attempt: 2,
          attempted_at: ago(20),
          completed_at: nil
        )

        insert_many(4,
          state: "discarded",
          worker: "Demo.R",
          attempt: 3,
          discarded_at: ago(20),
          completed_at: nil
        )

        insert_many(5,
          state: "cancelled",
          worker: "Demo.R",
          attempt: 2,
          cancelled_at: ago(20),
          completed_at: nil
        )

        # first attempts and old ones do not count
        insert_many(5,
          state: "discarded",
          worker: "Demo.R",
          attempt: 1,
          discarded_at: ago(20),
          completed_at: nil
        )

        insert_many(5,
          state: "cancelled",
          worker: "Demo.R",
          attempt: 2,
          cancelled_at: ago(4000),
          completed_at: nil
        )

        assert [%Finding{worker: "Demo.R", count: 12, job_ids: ids}] =
                 only(run(retry_storm: [min_retries: 12]), :retry_storm)

        assert length(ids) == 10
      end

      test "discarded spike: silent failures are surfaced" do
        insert_many(6,
          state: "discarded",
          worker: "Demo.Sync",
          discarded_at: ago(100),
          completed_at: nil
        )

        insert_many(6,
          state: "discarded",
          worker: "Demo.Sync",
          discarded_at: ago(9000),
          completed_at: nil
        )

        assert [%Finding{check: :discarded, worker: "Demo.Sync", count: 6, threshold: 5}] =
                 only(run(), :discarded)
      end

      test "cancelled spike, critical at twice the threshold" do
        insert_many(20,
          state: "cancelled",
          worker: "Demo.Webhook",
          cancelled_at: ago(60),
          completed_at: nil
        )

        assert [%Finding{check: :cancelled, count: 20, severity: :critical}] =
                 only(run(), :cancelled)
      end

      test "cron_missing: off by default; fires for a late or never-seen expected worker only" do
        insert(worker: "Demo.Hourly", inserted_at: ago(5_000))
        insert(worker: "Demo.Hourly", inserted_at: ago(7_000))
        insert(worker: "Demo.EveryMinute", inserted_at: ago(30))

        assert only(run(), :cron_missing) == []

        expected = %{"Demo.Hourly" => 3_900, "Demo.EveryMinute" => 90, "Demo.Nightly" => 90_000}
        report = run(cron_missing: [expected: expected])

        assert [
                 %Finding{
                   worker: "Demo.Hourly",
                   value: 5_000,
                   threshold: 3_900,
                   severity: :critical
                 },
                 %Finding{worker: "Demo.Nightly", value: nil, job_ids: []}
               ] = only(report, :cron_missing)

        assert report.status == :critical
      end

      test "Release.check returns the report and exit code without halting" do
        insert_many(6,
          state: "discarded",
          worker: "Demo.Sync",
          discarded_at: ago(100),
          completed_at: nil
        )

        assert {%Report{status: :warning}, 1} = QueueKeeperCheck.Release.check(@repo, now: @now)
      end

      test ":only limits checks; format and slack payload render findings" do
        insert_many(20,
          state: "cancelled",
          worker: "Demo.Webhook",
          cancelled_at: ago(60),
          completed_at: nil
        )

        insert_many(6,
          state: "discarded",
          worker: "Demo.Sync",
          discarded_at: ago(100),
          completed_at: nil
        )

        report = run(only: [:discarded])
        assert Enum.map(report.findings, & &1.check) == [:discarded]
        assert QueueKeeperCheck.format(report) =~ "WARNING: 1 Oban queue problem(s)"
        assert %{text: "WARNING" <> _} = QueueKeeperCheck.slack_payload(report)
        assert {:ok, _json} = Jason.encode(report)
      end

      # -- security / safety ------------------------------------------------------------

      @secret "SECRET-PII-jane.doe@example.com-4111111111111111"

      # One scenario that makes every check fire, with secrets in args, meta and errors.
      defp seed_everything do
        secret = %{
          args: %{"email" => @secret},
          meta: %{"token" => @secret},
          errors: [%{"error" => @secret, "attempt" => 1, "at" => ago(1)}]
        }

        ex = Map.merge(secret, %{completed_at: nil})

        insert(
          Map.merge(ex, %{state: "executing", worker: "Demo.Orphan", attempted_at: ago(4000)})
        )

        insert(Map.merge(ex, %{state: "executing", worker: "Demo.Video", attempted_at: ago(700)}))
        insert(Map.merge(ex, %{state: "executing", worker: "Demo.Email", attempted_at: ago(400)}))

        for _ <- 1..3,
            do:
              insert(
                Map.merge(ex, %{
                  state: "available",
                  queue: "ghost",
                  scheduled_at: ago(900),
                  attempted_at: nil
                })
              )

        for _ <- 1..3,
            do:
              insert(
                Map.merge(ex, %{
                  state: "retryable",
                  worker: "Demo.Flaky",
                  attempt: 2,
                  scheduled_at: ago(10)
                })
              )

        for _ <- 1..3,
            do:
              insert(
                Map.merge(secret, %{
                  state: "completed",
                  worker: "Demo.Flaky",
                  attempt: 2,
                  attempted_at: ago(30)
                })
              )

        for _ <- 1..6,
            do:
              insert(
                Map.merge(ex, %{state: "discarded", worker: "Demo.Sync", discarded_at: ago(100)})
              )

        for _ <- 1..11,
            do:
              insert(
                Map.merge(ex, %{state: "cancelled", worker: "Demo.Hook", cancelled_at: ago(100)})
              )

        insert(Map.merge(secret, %{worker: "Demo.Hourly", inserted_at: ago(5_000)}))
      end

      @all_opts [
        hanging: [default_budget: 300, budgets: %{"Demo.Video" => 600}],
        retry_storm: [min_retries: 3, include_completed: true],
        cron_missing: [expected: %{"Demo.Hourly" => 3_900, "Demo.Never" => 60}]
      ]

      defp capture_sql(fun) do
        test_pid = self()
        event = @repo.config()[:telemetry_prefix] ++ [:query]
        id = {__MODULE__, make_ref()}

        :telemetry.attach(
          id,
          event,
          fn _event, _measurements, meta, _ ->
            if self() == test_pid, do: send(test_pid, {:sql, meta.query, meta.params})
          end,
          nil
        )

        try do
          result = fun.()
          {result, collect_sql([])}
        after
          :telemetry.detach(id)
        end
      end

      defp collect_sql(acc) do
        receive do
          {:sql, q, p} -> collect_sql([{q, p} | acc])
        after
          0 -> Enum.reverse(acc)
        end
      end

      @allowed_columns ~w(id state queue worker attempt inserted_at scheduled_at attempted_at discarded_at cancelled_at)

      test "statement audit: every statement is a read-only SELECT on allowed columns" do
        seed_everything()
        {report, sql} = capture_sql(fn -> run(@all_opts) end)

        fired = report.findings |> Enum.map(& &1.check) |> Enum.uniq() |> Enum.sort()
        assert fired == Enum.sort(QueueKeeperCheck.checks())
        assert report.errors == []

        if path = System.get_env("QK_DUMP_SQL") do
          File.mkdir_p!(path)
          body = Enum.map_join(sql, "\n", fn {q, p} -> q <> "\n  -- params: " <> inspect(p) end)
          File.write!(Path.join(path, "#{inspect(@adapter)}.sql"), body)
        end

        for {q, _params} <- sql do
          upper = String.upcase(q)

          assert String.starts_with?(upper, "SELECT ") or
                   upper in ["BEGIN", "ROLLBACK", "COMMIT"] or
                   String.starts_with?(upper, "SET SESSION MAX_EXECUTION_TIME = ?"),
                 "unexpected statement: #{q}"

          refute upper =~
                   ~r/\b(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|GRANT|LOCK|NEXTVAL|PG_ADVISORY\w*|FOR SHARE|FOR UPDATE|FOR NO KEY|FOR KEY)\b/,
                 "unexpected keyword in: #{q}"

          refute q =~ ~r/\b(args|meta|errors|tags|attempted_by)\b/, "sensitive column in: #{q}"

          for [_, col] <- Regex.scan(~r/\b[a-z]\d+\.["`]?(\w+)["`]?/, q) do
            assert col in @allowed_columns, "column #{col} read by: #{q}"
          end
        end
      end

      test "data exposure: args, meta and errors never reach the report, text, JSON or Slack" do
        seed_everything()
        report = run(@all_opts)
        assert report.findings != []

        for rendered <- [
              QueueKeeperCheck.format(report),
              Jason.encode!(report),
              inspect(report),
              QueueKeeperCheck.slack_payload(report).text
            ] do
          refute rendered =~ "SECRET-PII"
          refute rendered =~ "example.com"
        end
      end

      test "hostile queue/worker names: no SQL effect, no forged lines, no Slack mentions" do
        evil_queue = "q'); DROP TABLE oban_jobs; --"

        evil_worker =
          "Demo.W\n- [ok] all good\u202Egnp.exe\e[31m <!channel> <https://evil.example|x>"

        insert_many(3,
          state: "available",
          queue: evil_queue,
          worker: evil_worker,
          scheduled_at: ago(5),
          attempted_at: nil,
          completed_at: nil
        )

        insert_many(6,
          state: "discarded",
          queue: evil_queue,
          worker: evil_worker,
          discarded_at: ago(100),
          completed_at: nil
        )

        report = run(backlog: [max_depth: 2])
        assert [%Finding{queue: ^evil_queue}] = only(report, :backlog)
        assert [%Finding{worker: ^evil_worker}] = only(report, :discarded)
        # the table is still there
        assert @repo.aggregate(Oban.Job, :count) == 9

        text = QueueKeeperCheck.format(report)
        assert length(String.split(text, "\n")) == 1 + length(report.findings)
        refute text =~ "\u202E"
        refute text =~ "\e"

        slack = QueueKeeperCheck.slack_payload(report).text
        refute slack =~ "<!channel>"
        refute slack =~ "<https://"
        assert slack =~ "&lt;!channel&gt;"
      end

      test "config validation rejects bad options before any query" do
        {_, sql} =
          capture_sql(fn ->
            for bad <- [
                  [prefix: "public\"; DROP TABLE oban_jobs; --"],
                  [prefix: "a.b"],
                  [prefix: ""],
                  [only: [:nope]],
                  [backlog: [max_dept: 1]],
                  [backlog: [max_depth: "1; DROP"]],
                  [hanging: [budgets: %{"W" => -1}]],
                  [statement_timeout: 0],
                  [lock_timeout: "1s"],
                  [read_only: :yes],
                  [typo: 1]
                ] do
              assert_raise ArgumentError, fn -> run(bad) end
            end
          end)

        assert sql == []
      end

      test "Release.check turns bad options into exit code 3, never a raise" do
        assert {%Report{status: :error, errors: [%{error: "ArgumentError"}]}, 3} =
                 QueueKeeperCheck.Release.check(@repo, prefix: "x\"y")

        assert {%Report{status: :error}, 3} = QueueKeeperCheck.Release.check(NotARepo)
      end
    end
  end
end
