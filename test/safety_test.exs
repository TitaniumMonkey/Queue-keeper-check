defmodule QueueKeeperCheck.PostgresSafetyTest do
  @moduledoc """
  Postgres-specific safety properties, against real connections (not only the sandbox).
  Uses private schemas (qk_ro, qk_lock, qk_legacy) so it never touches the rows the
  sandboxed suites see.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias QueueKeeperCheck.{BadPwRepo, DownRepo, Guard, Release, Report, RoRepo, TestRepo}

  @now ~U[2026-10-22 12:00:00.000000Z]

  setup_all do
    pg = pg!()

    for sql <- [
          "DROP SCHEMA IF EXISTS qk_ro CASCADE",
          "DROP SCHEMA IF EXISTS qk_lock CASCADE",
          "DROP SCHEMA IF EXISTS qk_legacy CASCADE",
          "CREATE SCHEMA qk_ro",
          "CREATE SCHEMA qk_lock",
          "CREATE SCHEMA qk_legacy",
          "CREATE TABLE qk_ro.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)",
          "CREATE TABLE qk_lock.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)",
          # an older Oban schema: no discarded_at / cancelled_at columns
          "CREATE TABLE qk_legacy.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)",
          "ALTER TABLE qk_legacy.oban_jobs DROP COLUMN discarded_at, DROP COLUMN cancelled_at",
          """
          INSERT INTO qk_ro.oban_jobs (state, queue, worker, args, meta, errors, attempt, inserted_at, scheduled_at, discarded_at)
          SELECT 'discarded', 'default', 'Demo.Sync', '{"email":"SECRET-PII"}', '{}', '{}', 1, now(), now(), now()
          FROM generate_series(1, 6)
          """,
          "INSERT INTO qk_lock.oban_jobs (state, queue, worker, args) VALUES ('available', 'default', 'Demo.W', '{}')",
          # least-privilege role: connect + SELECT on one table, nothing else
          "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'qk_readonly') THEN CREATE ROLE qk_readonly LOGIN PASSWORD 'qk-readonly-test-pw'; END IF; END $$",
          "GRANT CONNECT ON DATABASE queue_keeper_check_test TO qk_readonly",
          "GRANT USAGE ON SCHEMA qk_ro TO qk_readonly",
          "GRANT SELECT ON qk_ro.oban_jobs TO qk_readonly"
        ],
        do: Postgrex.query!(pg, sql, [])

    on_exit(fn ->
      pg = pg!()
      Postgrex.query!(pg, "DROP SCHEMA IF EXISTS qk_ro, qk_lock, qk_legacy CASCADE", [])

      Postgrex.query!(
        pg,
        "REVOKE CONNECT ON DATABASE queue_keeper_check_test FROM qk_readonly",
        []
      )
    end)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end

  defp pg! do
    {:ok, pid} =
      Postgrex.start_link(
        hostname: "localhost",
        username: "postgres",
        password: "postgres",
        database: "queue_keeper_check_test"
      )

    pid
  end

  defp guard(opts \\ []), do: Keyword.merge(QueueKeeperCheck.Config.guard_defaults(), opts)

  test "the guard makes the server reject writes, and rolls back cleanly" do
    err =
      assert_raise Postgrex.Error, fn ->
        Guard.run(TestRepo, guard(), fn ->
          TestRepo.insert!(%Oban.Job{worker: "W", queue: "q", args: %{}})
        end)
      end

    assert err.postgres.code == :read_only_sql_transaction

    # the caller's connection is still usable afterwards
    assert %Oban.Job{} = TestRepo.insert!(%Oban.Job{worker: "W", queue: "q", args: %{}})
  end

  test "statement_timeout is enforced server-side" do
    {micros, err} =
      :timer.tc(fn ->
        assert_raise Postgrex.Error, fn ->
          Guard.run(TestRepo, guard(statement_timeout: 100), fn ->
            TestRepo.query!("SELECT pg_sleep(3)")
          end)
        end
      end)

    assert err.postgres.code == :query_canceled
    assert micros < 2_000_000
  end

  test "lock_timeout: a check gives up instead of queueing behind an exclusive lock" do
    locker = pg!()
    parent = self()

    task =
      Task.async(fn ->
        Postgrex.transaction(locker, fn conn ->
          Postgrex.query!(conn, "LOCK TABLE qk_lock.oban_jobs IN ACCESS EXCLUSIVE MODE", [])
          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked, 5_000

    {micros, report} =
      :timer.tc(fn ->
        QueueKeeperCheck.run(TestRepo, prefix: "qk_lock", lock_timeout: 100, now: @now)
      end)

    send(task.pid, :release)
    Task.await(task)

    assert report.status == :error
    assert length(report.errors) == 7
    assert Enum.all?(report.errors, &(&1.message =~ "lock_not_available"))
    assert micros < 5_000_000
    assert Release.exit_code(report) == 3
  end

  test "a long-running check does not block Oban's row writes (AccessShareLock only)" do
    writer = pg!()

    task =
      Task.async(fn ->
        Process.sleep(100)

        :timer.tc(fn ->
          Postgrex.query!(
            writer,
            "UPDATE qk_lock.oban_jobs SET state = 'executing', attempted_at = now()",
            []
          )

          Postgrex.query!(
            writer,
            "INSERT INTO qk_lock.oban_jobs (state, queue, worker, args) VALUES ('available', 'default', 'Demo.W', '{}')",
            []
          )

          Postgrex.query!(writer, "DELETE FROM qk_lock.oban_jobs WHERE state = 'executing'", [])
        end)
      end)

    Guard.run(TestRepo, guard(), fn ->
      TestRepo.query!("SELECT count(*), pg_sleep(1) FROM qk_lock.oban_jobs")
    end)

    {write_micros, _} = Task.await(task)
    assert write_micros < 500_000
  end

  test "refuses to run inside the caller's transaction and leaves it intact" do
    {:ok, report} =
      TestRepo.transaction(fn ->
        report = QueueKeeperCheck.run(TestRepo, now: @now)
        # the caller's transaction is not read-only and not aborted
        TestRepo.insert!(%Oban.Job{worker: "W", queue: "q", args: %{}})
        report
      end)

    assert %Report{status: :error, errors: [%{error: "ArgumentError", message: msg}]} = report
    assert msg =~ "inside an open transaction"
  end

  test "prefix mismatch / missing table: every check reports an error, exit code 3" do
    report = QueueKeeperCheck.run(TestRepo, prefix: "no_such_schema", now: @now)
    assert report.status == :error
    assert length(report.errors) == 7
    assert Enum.all?(report.errors, &(&1.message =~ "undefined_table"))

    assert QueueKeeperCheck.format(report) =~
             "ERROR: 0 Oban queue problem(s), 7 check(s) could not run"
  end

  test "older Oban schema: checks needing missing columns fail alone, the rest still run" do
    report = QueueKeeperCheck.run(TestRepo, prefix: "qk_legacy", now: @now)
    failed = report.errors |> Enum.map(& &1.check) |> Enum.sort()
    assert failed == [:cancelled, :discarded, :retry_storm]
    assert Enum.all?(report.errors, &(&1.message =~ "undefined_column"))
    assert report.status == :error
  end

  test "works under a least-privilege role (SELECT on oban_jobs only), which cannot write" do
    assert {%Report{status: :warning, errors: [], findings: [f]}, 1} =
             Release.check(RoRepo, prefix: "qk_ro")

    assert f.check == :discarded
    assert Process.whereis(RoRepo) == nil, "Release.check must stop the repo it started"

    {:ok, _} = RoRepo.start_link(pool_size: 1)

    try do
      assert_raise Postgrex.Error, ~r/permission denied/, fn ->
        RoRepo.query!("INSERT INTO qk_ro.oban_jobs (worker, queue, args) VALUES ('w', 'q', '{}')")
      end

      assert_raise Postgrex.Error, ~r/permission denied/, fn ->
        RoRepo.query!("SELECT count(*) FROM public.oban_jobs")
      end
    after
      Supervisor.stop(RoRepo)
    end
  end

  test "database down: exit code 3, bounded time, no credentials in output or logs" do
    {result, log} =
      with_log(fn -> :timer.tc(fn -> Release.check(DownRepo, now: @now) end) end)

    {micros, {report, code}} = result
    assert code == 3
    assert report.status == :error
    assert [%{error: "DBConnection.ConnectionError"} | skipped] = report.errors
    assert Enum.all?(skipped, &(&1.error == "skipped"))
    assert micros < 10_000_000
    assert Process.whereis(DownRepo) == nil

    for text <- [log, QueueKeeperCheck.format(report), Jason.encode!(report)] do
      refute text =~ "qk-down-secret-pw"
    end
  end

  test "wrong password: exit code 3, password never printed" do
    {{report, code}, log} = with_log(fn -> Release.check(BadPwRepo, now: @now) end)
    assert code == 3
    assert QueueKeeperCheck.format(report) =~ "ConnectionError"

    for text <- [log, QueueKeeperCheck.format(report), Jason.encode!(report)] do
      refute text =~ "qk-wrong-secret-pw"
    end
  end
end

defmodule QueueKeeperCheck.SQLiteSafetyTest do
  use ExUnit.Case, async: false
  alias QueueKeeperCheck.{LiteRoRepo, Release, Report}

  test "works on a SQLite database opened read-only, which cannot be written" do
    assert {%Report{status: :ok, errors: []}, 0} = Release.check(LiteRoRepo)

    {:ok, _} = LiteRoRepo.start_link()

    try do
      assert_raise Exqlite.Error, ~r/readonly/, fn ->
        LiteRoRepo.query!("INSERT INTO oban_jobs (worker, queue, args) VALUES ('w', 'q', '{}')")
      end
    after
      Supervisor.stop(LiteRoRepo)
    end
  end
end

defmodule QueueKeeperCheck.MySQLSafetyTest do
  use ExUnit.Case, async: false
  @moduletag :mysql
  alias QueueKeeperCheck.{Guard, MyRepo, MyRoRepo, Release, Report}

  setup_all do
    {:ok, conn} =
      MyXQL.start_link(
        hostname: System.get_env("QK_MYSQL_HOST", "127.0.0.1"),
        port: String.to_integer(System.get_env("QK_MYSQL_PORT", "3307")),
        username: System.get_env("QK_MYSQL_USER", "root"),
        password: System.get_env("QK_MYSQL_PASSWORD", "")
      )

    for sql <- [
          "DROP USER IF EXISTS 'qk_readonly'@'%'",
          "CREATE USER 'qk_readonly'@'%' IDENTIFIED BY 'qk-readonly-test-pw'",
          "GRANT SELECT ON queue_keeper_check_test.oban_jobs TO 'qk_readonly'@'%'"
        ],
        do: MyXQL.query!(conn, sql, [], query_type: :text)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyRepo)
  end

  test "max_execution_time is applied during a check and restored afterwards" do
    before = MyRepo.query!("SELECT @@SESSION.max_execution_time").rows

    inside =
      Guard.run(
        MyRepo,
        Keyword.merge(QueueKeeperCheck.Config.guard_defaults(), statement_timeout: 1234),
        fn ->
          MyRepo.query!("SELECT @@SESSION.max_execution_time").rows
        end
      )

    assert inside == [[1234]]
    assert MyRepo.query!("SELECT @@SESSION.max_execution_time").rows == before
  end

  test "max_execution_time interrupts a slow SELECT" do
    {micros, result} =
      :timer.tc(fn ->
        try do
          Guard.run(
            MyRepo,
            Keyword.merge(QueueKeeperCheck.Config.guard_defaults(), statement_timeout: 200),
            fn ->
              # a deliberately slow SELECT (cross join over a recursive CTE)
              MyRepo.query!("""
              WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)
              SELECT count(*) FROM n a, n b, n c
              """)
            end
          )
        rescue
          e in MyXQL.Error -> e
        end
      end)

    assert %MyXQL.Error{mysql: %{code: 3024}} = result
    assert micros < 3_000_000
  end

  test "works under a SELECT-only MySQL user, which cannot write" do
    assert {%Report{errors: []}, code} = Release.check(MyRoRepo)
    assert code in [0, 1, 2]

    {:ok, _} = MyRoRepo.start_link(pool_size: 1)

    try do
      assert_raise MyXQL.Error, ~r/denied/, fn ->
        MyRoRepo.query!("INSERT INTO oban_jobs (worker, queue, args) VALUES ('w', 'q', '{}')")
      end
    after
      Supervisor.stop(MyRoRepo)
    end
  end
end
