defmodule Mix.Tasks.QueueKeeper.Check do
  @shortdoc "Run the Oban queue self-check and exit non-zero on findings"
  @moduledoc """
      mix queue_keeper.check --repo MyApp.Repo [--prefix public] [--json]
                             [--statement-timeout MS] [--lock-timeout MS]

  Compiles the project and loads its configuration (including `config/runtime.exs`), then
  starts **only the repo** (pool of 1) via `QueueKeeperCheck.Release.check/2`: your
  application, Oban, its queues and plugins are not started. Runs the checks with default
  thresholds, prints the report and exits with status 0 (ok), 1 (warning), 2 (critical)
  or 3 (error: bad arguments, unknown repo, or a check could not complete). Suitable for
  cron or CI.
  """
  use Mix.Task

  @switches [
    repo: :string,
    prefix: :string,
    json: :boolean,
    statement_timeout: :integer,
    lock_timeout: :integer
  ]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {[_ | _] = opts, [], []} ->
        if !is_binary(opts[:repo]), do: usage!()

        # Compile and load config without starting any application.
        Mix.Task.run("app.config")
        repo = Module.concat([opts[:repo]])
        check_opts = Keyword.take(opts, [:prefix, :statement_timeout, :lock_timeout])
        {report, code} = QueueKeeperCheck.Release.check(repo, check_opts)

        Mix.shell().info(
          if opts[:json], do: Jason.encode!(report), else: QueueKeeperCheck.format(report)
        )

        if code != 0, do: exit({:shutdown, code})
        :ok

      _ ->
        usage!()
    end
  end

  defp usage! do
    Mix.shell().error(
      "usage: mix queue_keeper.check --repo MyApp.Repo [--prefix public] [--json] " <>
        "[--statement-timeout MS] [--lock-timeout MS]"
    )

    exit({:shutdown, 3})
  end
end
