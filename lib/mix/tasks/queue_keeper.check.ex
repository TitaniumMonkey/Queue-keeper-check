defmodule Mix.Tasks.QueueKeeper.Check do
  @shortdoc "Run the Oban queue self-check and exit non-zero on findings"
  @moduledoc """
      mix queue_keeper.check --repo MyApp.Repo [--prefix public] [--json]

  Starts the app, runs `QueueKeeperCheck.run/2` with default thresholds, prints the report,
  and exits with status 0 (ok), 1 (warning) or 2 (critical). Suitable for cron or CI.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [repo: :string, prefix: :string, json: :boolean])

    repo = Module.concat([opts[:repo] || Mix.raise("--repo is required")])
    Mix.Task.run("app.start")

    report = QueueKeeperCheck.run(repo, Keyword.take(opts, [:prefix]))

    Mix.shell().info(
      if opts[:json], do: Jason.encode!(report), else: QueueKeeperCheck.format(report)
    )

    case report.status do
      :ok -> :ok
      :warning -> exit({:shutdown, 1})
      :critical -> exit({:shutdown, 2})
    end
  end
end
