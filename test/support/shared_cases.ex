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

        assert [
                 %Finding{
                   check: :retry_storm,
                   worker: "Demo.Flaky",
                   count: 25,
                   threshold: 20,
                   severity: :warning
                 }
               ] =
                 only(run(), :retry_storm)
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
    end
  end
end
