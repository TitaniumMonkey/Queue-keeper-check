defmodule QueueKeeperCheck.TestRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule QueueKeeperCheck.LiteRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.SQLite3
end

# MySQL 8.4+ repo for Oban's Dolphin engine. Only set up when QK_MYSQL=1 (see test_helper.exs).
defmodule QueueKeeperCheck.MyRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.MyXQL
end

defmodule QueueKeeperCheck.TestMigration do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end

# Repos for test/safety_test.exs (no sandbox: they exercise real connections and roles).
defmodule QueueKeeperCheck.RoRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule QueueKeeperCheck.DownRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule QueueKeeperCheck.BadPwRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.Postgres
end

defmodule QueueKeeperCheck.LiteRoRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.SQLite3
end

defmodule QueueKeeperCheck.MyRoRepo do
  use Ecto.Repo, otp_app: :queue_keeper_check, adapter: Ecto.Adapters.MyXQL
end
