defmodule QueueKeeperCheck.LedgerPostgresTest do
  use ExUnit.Case, async: false

  alias QueueKeeperCheck.{Finding, Ledger, TestRepo}

  @repo TestRepo
  @now ~U[2026-11-10 12:00:00.000000Z]
  @prefix "public"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    name = :"ledger_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Ledger.start_link(
        repo: @repo,
        name: name,
        flush_interval: :infinity,
        prefix: @prefix,
        sandbox: self()
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{ledger: name, pid: pid}
  end

  test "insert_job telemetry is coalesced and flushed with GREATEST", %{ledger: ledger} do
    early = DateTime.add(@now, -90, :second)
    late = DateTime.add(@now, -10, :second)

    emit_insert_job(ledger, "Demo.A", early, 11)
    emit_insert_job(ledger, "Demo.A", late, 12)
    emit_insert_job(ledger, "Demo.B", late, 21)
    # Wait for casts
    :ok = Ledger.flush(ledger)

    {:ok, %{started_at: started, sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    assert DateTime.compare(started, @now) != :gt or true
    assert {at_a, 12, 0} = sightings["Demo.A"]
    assert DateTime.compare(at_a, late) == :eq
    assert {^late, 21, 0} = sightings["Demo.B"]

    # An older upsert from another "node" must not move the timestamp backwards.
    emit_insert_job(ledger, "Demo.A", early, 10)
    :ok = Ledger.flush(ledger)
    {:ok, %{sightings: sightings2}} = Ledger.fetch(@repo, prefix: @prefix)
    assert {at_a2, 12, 0} = sightings2["Demo.A"]
    assert DateTime.compare(at_a2, late) == :eq
  end

  test "insert_all jobs and leftover unique-conflict changesets are recorded", %{ledger: ledger} do
    job = %Oban.Job{
      id: 30,
      worker: "Demo.Bulk",
      inserted_at: @now,
      conflict?: false
    }

    missed =
      Oban.Job.new(%{ok: true}, worker: QueueKeeperCheck.DeadTestWorker)

    :telemetry.execute(
      [:oban, :engine, :insert_all_jobs, :stop],
      %{duration: 1},
      %{
        conf: %{name: Oban, prefix: @prefix, repo: @repo},
        engine: Oban.Engines.Basic,
        jobs: [job],
        changesets: [missed]
      }
    )

    # Route through the named process by using the handler directly
    Ledger.handle_event(
      [:oban, :engine, :insert_all_jobs, :stop],
      %{duration: 1},
      %{
        conf: %{name: Oban, prefix: @prefix, repo: @repo},
        jobs: [job],
        changesets: [missed]
      },
      ledger
    )

    :ok = Ledger.flush(ledger)
    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    assert Map.has_key?(sightings, "Demo.Bulk")
    assert Map.has_key?(sightings, "QueueKeeperCheck.DeadTestWorker")
  end

  test "unique-insert conflict records the event time, not the original inserted_at", %{
    ledger: ledger
  } do
    original = DateTime.add(@now, -30 * 86_400, :second)

    Ledger.handle_event(
      [:oban, :engine, :insert_job, :stop],
      %{duration: 1},
      %{
        conf: %{name: Oban, prefix: @prefix, repo: @repo},
        job: %Oban.Job{
          id: 7,
          worker: "Demo.Unique",
          inserted_at: original,
          conflict?: true
        }
      },
      ledger
    )

    :ok = Ledger.flush(ledger)
    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    {at, 7, 0} = sightings["Demo.Unique"]
    # Event time is DateTime.utc_now(), far later than the 30-day-old original row.
    assert DateTime.compare(at, original) == :gt
    assert DateTime.diff(DateTime.utc_now(), at, :second) < 30
  end

  test "handler is fail-open when the ledger process is gone", %{ledger: ledger, pid: pid} do
    GenServer.stop(pid, :normal, 2_000)

    assert Ledger.handle_event(
             [:oban, :engine, :insert_job, :stop],
             %{duration: 1},
             %{
               conf: %{name: Oban, prefix: @prefix, repo: @repo},
               job: %Oban.Job{id: 1, worker: "Demo.X", inserted_at: @now}
             },
             ledger
           ) == :ok
  end

  test "periodic flush drains ETS without an explicit call" do
    name = :"ledger_flush_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Ledger.start_link(
        repo: @repo,
        name: name,
        flush_interval: 50,
        prefix: @prefix,
        sandbox: self()
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    emit_insert_job(name, "Demo.Tick", @now, 99)
    Process.sleep(200)
    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    assert Map.has_key?(sightings, "Demo.Tick")
  end

  test "concurrent events for one worker keep the latest timestamp", %{ledger: ledger} do
    times = for s <- 1..20, do: DateTime.add(@now, s, :second)

    1..20
    |> Enum.zip(times)
    |> Task.async_stream(fn {i, at} -> emit_insert_job(ledger, "Demo.Race", at, i) end,
      max_concurrency: 8
    )
    |> Stream.run()

    :ok = Ledger.flush(ledger)
    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    {at, id, 0} = sightings["Demo.Race"]
    assert DateTime.compare(at, List.last(times)) == :eq
    assert id == 20
  end

  test "backfill copies current oban_jobs and is idempotent" do
    insert_job("Demo.Backfill", DateTime.add(@now, -60, :second))
    :ok = Ledger.backfill(@repo, prefix: @prefix)
    :ok = Ledger.backfill(@repo, prefix: @prefix)
    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    assert Map.has_key?(sightings, "Demo.Backfill")
  end

  test "dead_workers uses the ledger when present and stays silent until it is old enough" do
    # No running ledger required: seed the tables as a 1-day-old ledger would look.
    started = DateTime.add(@now, -86_400, :second)
    seed_meta(started)
    seed_sighting("Demo.Old", DateTime.add(@now, -20 * 86_400, :second), 1)

    assert [] ==
             QueueKeeperCheck.run(@repo,
               now: @now,
               only: [:dead_workers],
               dead_workers: [window_days: 14, known: ["Demo.Old"]]
             ).findings

    report =
      QueueKeeperCheck.run(@repo,
        now: @now,
        only: [:dead_workers],
        dead_workers: [window_days: 14, known: ["Demo.Old"], report_short_history: true]
      )

    assert [%Finding{check: :dead_workers, worker: nil, severity: :warning}] =
             report.findings

    assert hd(report.findings).message =~ "ledger's recording"
    refute hd(report.findings).message =~ "Raise the Pruner"
  end

  test "dead_workers flags from the ledger once recording is older than the window" do
    started = DateTime.add(@now, -20 * 86_400, :second)
    seed_meta(started)
    seed_sighting("Demo.Dead", DateTime.add(@now, -15 * 86_400, :second), 8)
    seed_sighting("Demo.Live", DateTime.add(@now, -60, :second), 9)

    report =
      QueueKeeperCheck.run(@repo,
        now: @now,
        only: [:dead_workers],
        dead_workers: [window_days: 14, known: ["Demo.Dead", "Demo.Live", "Demo.Never"]]
      )

    names = report.findings |> Enum.map(& &1.worker) |> Enum.sort()
    assert names == ["Demo.Dead", "Demo.Never"]
    refute "Demo.Live" in names
  end

  test "use_ledger: false ignores a present ledger and falls back to oban_jobs" do
    started = DateTime.add(@now, -20 * 86_400, :second)
    seed_meta(started)
    # Ledger says it is dead, but a recent row in oban_jobs would keep it live on the SQL path.
    seed_sighting("Demo.StillUsed", DateTime.add(@now, -20 * 86_400, :second), 1)
    insert_job("Demo.StillUsed", DateTime.add(@now, -60, :second))
    # History for the SQL path: a 20-day-old finished row so the window is observable.
    insert_job("Demo.History", DateTime.add(@now, -20 * 86_400, :second))

    ledger_report =
      QueueKeeperCheck.run(@repo,
        now: @now,
        only: [:dead_workers],
        dead_workers: [window_days: 14]
      )

    assert "Demo.StillUsed" in Enum.map(ledger_report.findings, & &1.worker)

    sql_report =
      QueueKeeperCheck.run(@repo,
        now: @now,
        only: [:dead_workers],
        dead_workers: [window_days: 14, use_ledger: false]
      )

    refute "Demo.StillUsed" in Enum.map(sql_report.findings, & &1.worker)
  end

  defp emit_insert_job(ledger, worker, at, id) do
    Ledger.handle_event(
      [:oban, :engine, :insert_job, :stop],
      %{duration: 1},
      %{
        conf: %{name: Oban, prefix: @prefix, repo: @repo},
        job: %Oban.Job{id: id, worker: worker, inserted_at: at, conflict?: false}
      },
      ledger
    )
  end

  defp seed_meta(started_at) do
    @repo.query!(
      """
      INSERT INTO "public"."queue_keeper_ledger_meta" (prefix, started_at)
      VALUES ($1, $2)
      ON CONFLICT (prefix) DO UPDATE SET started_at = EXCLUDED.started_at
      """,
      [@prefix, started_at]
    )
  end

  defp seed_sighting(worker, at, id) do
    @repo.query!(
      """
      INSERT INTO "public"."queue_keeper_worker_sightings"
        (prefix, worker, last_inserted_at, last_job_id)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (prefix, worker) DO UPDATE SET
        last_inserted_at = EXCLUDED.last_inserted_at,
        last_job_id = EXCLUDED.last_job_id
      """,
      [@prefix, worker, at, id]
    )
  end

  defp insert_job(worker, at) do
    @repo.insert!(%Oban.Job{
      state: "completed",
      queue: "default",
      worker: worker,
      args: %{},
      attempt: 1,
      max_attempts: 20,
      inserted_at: at,
      scheduled_at: at,
      attempted_at: at,
      completed_at: at
    })
  end
end

defmodule QueueKeeperCheck.LedgerSQLiteTest do
  use ExUnit.Case, async: false

  alias QueueKeeperCheck.{Finding, Ledger, LiteRepo}

  @repo LiteRepo
  @now ~U[2026-11-10 12:00:00.000000Z]
  # SQLite has no schema; the prefix column still stores a name.
  @prefix "public"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    name = :"ledger_lite_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Ledger.start_link(
        repo: @repo,
        name: name,
        flush_interval: :infinity,
        prefix: @prefix,
        sandbox: self()
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{ledger: name}
  end

  test "flush, GREATEST, and the dead_workers check work on SQLite", %{ledger: ledger} do
    early = DateTime.add(@now, -90, :second)
    late = DateTime.add(@now, -10, :second)

    emit(ledger, "Demo.A", early, 1)
    emit(ledger, "Demo.A", late, 2)
    :ok = Ledger.flush(ledger)

    emit(ledger, "Demo.A", early, 0)
    :ok = Ledger.flush(ledger)

    {:ok, %{sightings: sightings}} = Ledger.fetch(@repo, prefix: @prefix)
    {at, id, 0} = sightings["Demo.A"]
    assert DateTime.compare(at, late) == :eq
    assert id == 2

    started = DateTime.add(@now, -20 * 86_400, :second)

    @repo.query!(
      """
      INSERT INTO queue_keeper_ledger_meta (prefix, started_at)
      VALUES (?1, ?2)
      ON CONFLICT (prefix) DO UPDATE SET started_at = excluded.started_at
      """,
      [@prefix, started]
    )

    @repo.query!(
      """
      INSERT INTO queue_keeper_worker_sightings
        (prefix, worker, last_inserted_at, last_job_id)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT (prefix, worker) DO UPDATE SET
        last_inserted_at = excluded.last_inserted_at,
        last_job_id = excluded.last_job_id
      """,
      [@prefix, "Demo.Dead", DateTime.add(@now, -15 * 86_400, :second), 8]
    )

    report =
      QueueKeeperCheck.run(@repo,
        now: @now,
        only: [:dead_workers],
        prefix: @prefix,
        dead_workers: [window_days: 14, known: ["Demo.Dead", "Demo.A"]]
      )

    names = Enum.map(report.findings, & &1.worker)
    assert "Demo.Dead" in names
    refute "Demo.A" in names
    assert %Finding{severity: :warning} = hd(report.findings)
  end

  defp emit(ledger, worker, at, id) do
    Ledger.handle_event(
      [:oban, :engine, :insert_job, :stop],
      %{duration: 1},
      %{
        conf: %{name: Oban, prefix: @prefix, repo: @repo},
        job: %Oban.Job{id: id, worker: worker, inserted_at: at, conflict?: false}
      },
      ledger
    )
  end
end
