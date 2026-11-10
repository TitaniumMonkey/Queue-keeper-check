defmodule Mix.Tasks.QueueKeeper.DeadCode do
  @shortdoc "List Oban workers with no static callers and not in cron"
  @moduledoc """
      mix queue_keeper.dead_code [--json] [--ignore Worker] [--known Worker]

  Compiles the project, loads config (including `config/runtime.exs` via
  `app.config`), and lists `Oban.Worker` modules that have no compile-time call
  sites and are not in the Oban or Oban Pro crontab from application env.

  Needs the host app **compiled**; it does not start the application or Oban.
  Discover uses `Application.spec/2` and `Code.ensure_loaded/1`.

  A worker enqueued only through dynamic dispatch (a module name built at
  runtime with `Module.concat`, `apply/3` on a string, and similar) will show
  up here even if production still runs it. Treat the list as candidates, not
  proof. Runtime-only Pro cron rules stored in the database are not visible.

  Exit 0 if nothing looks dead, 1 if at least one worker is reported, 3 on
  usage errors.
  """
  use Mix.Task

  @switches [json: :boolean, ignore: :keep, known: :keep]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        Mix.Task.run("compile")
        Mix.Task.run("app.config")

        # Load the host app (and local umbrella apps) so Application.spec has
        # modules, without starting them or Oban.
        for app <- project_apps() do
          _ = Application.load(app)
        end

        scan_opts = [
          ignore: Keyword.get_values(opts, :ignore),
          known: Keyword.get_values(opts, :known)
        ]

        results = QueueKeeperCheck.DeadCode.scan(scan_opts)
        dead = Enum.filter(results, &(&1.status == :dead))

        Mix.shell().info(
          if opts[:json] do
            Jason.encode!(%{
              dead: Enum.map(dead, & &1.worker),
              live:
                for %{status: :live} = r <- results do
                  %{worker: r.worker, reason: r.reason, files: r.files}
                end
            })
          else
            format(dead, results)
          end
        )

        if dead != [], do: exit({:shutdown, 1})
        :ok

      _ ->
        Mix.shell().error(
          "usage: mix queue_keeper.dead_code [--json] [--ignore Worker] [--known Worker]"
        )

        exit({:shutdown, 3})
    end
  end

  defp project_apps do
    cond do
      not function_exported?(Mix.Project, :config, 0) ->
        []

      Mix.Project.umbrella?() ->
        for {app, _} <- Mix.Project.apps_paths(), do: app

      true ->
        List.wrap(Mix.Project.config()[:app])
    end
  end

  defp format([], results) do
    "OK: no Oban workers without static callers or cron entries (#{length(results)} scanned)"
  end

  defp format(dead, results) do
    header =
      "WARNING: #{length(dead)} Oban worker(s) with no static callers and not in cron " <>
        "(#{length(results)} scanned). Dynamic dispatch is a false positive; review before deleting."

    lines = Enum.map(dead, fn r -> "- #{r.worker}" end)
    Enum.join([header | lines], "\n")
  end
end
