defmodule QueueKeeperCheck.Ledger.Migration do
  @moduledoc """
  Creates the opt-in last-seen ledger tables.

  Add a migration in the host app and run it yourself; this library never migrates
  a database on its own:

      defmodule MyApp.Repo.Migrations.AddQueueKeeperLedger do
        use Ecto.Migration

        def up, do: QueueKeeperCheck.Ledger.Migration.up()
        def down, do: QueueKeeperCheck.Ledger.Migration.down()
      end

  Pass `prefix:` to put the tables in the same schema as that Oban instance
  (Postgres). The `prefix` column on each row still stores the Oban prefix, so a
  single schema can hold more than one instance if you need it.

  Tables:

  * `queue_keeper_worker_sightings` — primary key `(prefix, worker)`, plus
    `last_inserted_at` and nullable `last_job_id`
  * `queue_keeper_ledger_meta` — primary key `prefix`, plus `started_at` (when
    recording began for that prefix)
  """

  use Ecto.Migration

  @sightings "queue_keeper_worker_sightings"
  @meta "queue_keeper_ledger_meta"

  def up(opts \\ []) do
    prefix = opts[:prefix]

    create_if_not_exists table(@sightings, primary_key: false, prefix: prefix) do
      add(:prefix, :string, size: 63, null: false, primary_key: true)
      add(:worker, :string, size: 255, null: false, primary_key: true)
      add(:last_inserted_at, :utc_datetime_usec, null: false)
      add(:last_job_id, :bigint)
    end

    create_if_not_exists table(@meta, primary_key: false, prefix: prefix) do
      add(:prefix, :string, size: 63, null: false, primary_key: true)
      add(:started_at, :utc_datetime_usec, null: false)
    end
  end

  def down(opts \\ []) do
    prefix = opts[:prefix]
    drop_if_exists(table(@sightings, prefix: prefix))
    drop_if_exists(table(@meta, prefix: prefix))
  end
end
