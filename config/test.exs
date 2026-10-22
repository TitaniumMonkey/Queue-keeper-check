import Config

config :queue_keeper_check, QueueKeeperCheck.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "queue_keeper_check_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :queue_keeper_check, ecto_repos: [QueueKeeperCheck.TestRepo, QueueKeeperCheck.LiteRepo]
config :logger, level: :warning

config :queue_keeper_check, QueueKeeperCheck.LiteRepo,
  database: Path.expand("../tmp/queue_keeper_check_test.sqlite3", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# MySQL 8.4+ (Oban Dolphin engine). Opt-in: QK_MYSQL=1 mix test. Defaults match the local
# server started by dev/mysql84.sh (127.0.0.1:3307, root, no password).
config :queue_keeper_check, QueueKeeperCheck.MyRepo,
  username: System.get_env("QK_MYSQL_USER", "root"),
  password: System.get_env("QK_MYSQL_PASSWORD", ""),
  hostname: System.get_env("QK_MYSQL_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("QK_MYSQL_PORT", "3307")),
  database: "queue_keeper_check_test",
  pool: Ecto.Adapters.SQL.Sandbox
