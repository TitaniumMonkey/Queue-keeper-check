defmodule QueueKeeperCheck.DeadTestWorker do
  @moduledoc false
  # Loaded in the test VM so `:dead_workers` `discover: true` can find a real Oban.Worker.
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(_job), do: :ok
end
