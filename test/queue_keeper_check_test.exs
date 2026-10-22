defmodule QueueKeeperCheck.PostgresTest do
  use ExUnit.Case, async: true

  use QueueKeeperCheck.SharedCases,
    repo: QueueKeeperCheck.TestRepo,
    adapter: Ecto.Adapters.Postgres
end

defmodule QueueKeeperCheck.SQLiteTest do
  # SQLite allows one writer at a time, so this suite runs serially.
  use ExUnit.Case, async: false

  use QueueKeeperCheck.SharedCases,
    repo: QueueKeeperCheck.LiteRepo,
    adapter: Ecto.Adapters.SQLite3
end

defmodule QueueKeeperCheck.MySQLTest do
  # Opt-in (QK_MYSQL=1). Sandbox transactions isolate tests, but run serially to keep it simple.
  use ExUnit.Case, async: false
  @moduletag :mysql
  use QueueKeeperCheck.SharedCases, repo: QueueKeeperCheck.MyRepo, adapter: Ecto.Adapters.MyXQL
end
