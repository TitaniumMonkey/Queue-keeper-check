defmodule QueueKeeperCheck.DeadCodeDirectWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule QueueKeeperCheck.DeadCodeViaOptsWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule QueueKeeperCheck.DeadCodeCronWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule QueueKeeperCheck.DeadCodeDynamicWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule QueueKeeperCheck.DeadCodeAbandonedWorker do
  @moduledoc false
  use Oban.Worker, queue: :default
  @impl Oban.Worker
  def perform(_job), do: :ok
end

defmodule QueueKeeperCheck.DeadCodeEnqueuer do
  @moduledoc false
  def enqueue_direct do
    %{ok: true}
    |> QueueKeeperCheck.DeadCodeDirectWorker.new()
    |> Oban.insert()
  end

  def enqueue_via_opts do
    Oban.Job.new(%{ok: true}, worker: QueueKeeperCheck.DeadCodeViaOptsWorker)
  end

  # Only a runtime string; must look "dead" to the static scan.
  def enqueue_dynamic do
    name = "QueueKeeperCheck.DeadCodeDynamicWorker"
    mod = Module.concat(Elixir, name)
    apply(mod, :new, [%{ok: true}])
  end
end
