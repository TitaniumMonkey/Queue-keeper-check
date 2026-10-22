# A minimal host application used to verify, end to end, what `mix queue_keeper.check` and
# `QueueKeeperCheck.Release` start (and don't start) inside a real app with Oban, Cron and
# Pruner configured. Not part of the package. See dev/verify_host_app.sh.
defmodule HostApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :host_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: [
        {:queue_keeper_check, path: System.get_env("QK_PATH", "../..")},
        {:postgrex, "~> 0.17"}
      ],
      releases: [host_app: [include_executables_for: [:unix]]]
    ]
  end

  def application, do: [mod: {HostApp.Application, []}, extra_applications: [:logger]]
end
