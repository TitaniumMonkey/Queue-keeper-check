alias QueueKeeperCheck.{LiteRepo, MyRepo, TestMigration, TestRepo}

# MySQL (Dolphin engine) is opt-in because it needs a running MySQL 8.4+ server:
#   QK_MYSQL=1 mix test
mysql? = System.get_env("QK_MYSQL") == "1"
mysql = if mysql?, do: [{MyRepo, Ecto.Adapters.MyXQL}], else: []

unless mysql?,
  do: IO.puts("MySQL suite skipped (set QK_MYSQL=1 with a MySQL 8.4+ server to run it)")

for {repo, adapter} <- [
      {TestRepo, Ecto.Adapters.Postgres},
      {LiteRepo, Ecto.Adapters.SQLite3} | mysql
    ] do
  _ = adapter.storage_down(repo.config())
  :ok = adapter.storage_up(repo.config())
  # Migrate with a plain pool first (the migrator needs its own connection), then
  # restart the repo under the sandbox pool configured in config/test.exs.
  {:ok, pid} = repo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)
  Ecto.Migrator.up(repo, 1, TestMigration, log: false)
  Supervisor.stop(pid)
  {:ok, _} = repo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
end

ExUnit.start(exclude: if(mysql?, do: [], else: [:mysql]))
