defmodule HostApp.Repo do
  use Ecto.Repo, otp_app: :host_app, adapter: Ecto.Adapters.Postgres
end

defmodule HostApp.Worker do
  use Oban.Worker
  @impl true
  def perform(_job), do: :ok
end

defmodule HostApp.Application do
  use Application

  # Side effects a real app might have at boot. If the check starts the app, these show up.
  @impl true
  def start(_type, _args) do
    IO.puts(:stderr, "HOST_APP_STARTED")

    children = [
      HostApp.Repo,
      {Oban, Application.fetch_env!(:host_app, Oban)},
      {Task, fn -> HostApp.Repo.insert!(%Oban.Job{worker: "HostApp.BootSideEffect", queue: "default", args: %{}}) end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HostApp.Supervisor)
  end
end
