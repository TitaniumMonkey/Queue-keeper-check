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
  up here even if production still runs it. Treat the list as **review
  candidates**, not proof of dead code. Runtime-only Pro cron rules stored in
  the database are not visible. Missing BEAM debug info or empty compile paths
  make the result incomplete; the report and JSON `coverage` object say so.

  Exit 0 if there are no review candidates, 1 if at least one worker is
  reported, 3 on usage errors. JSON includes both `review_candidates` and a
  deprecated `dead` alias (the same list) for compatibility.
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

        %{workers: results, coverage: coverage} =
          QueueKeeperCheck.DeadCode.scan_report(scan_opts)

        candidates = Enum.filter(results, &(&1.status == :review_candidate))

        Mix.shell().info(
          if opts[:json] do
            Jason.encode!(%{
              review_candidates: Enum.map(candidates, & &1.worker),
              # Deprecated alias; same list as review_candidates.
              dead: Enum.map(candidates, & &1.worker),
              live:
                for %{status: :live} = r <- results do
                  %{worker: r.worker, reason: r.reason, files: r.files}
                end,
              coverage: %{
                beams_scanned: coverage.beams_scanned,
                beams_ok: coverage.beams_ok,
                beams_missing_debug_info: coverage.beams_missing_debug_info,
                beams_unreadable: coverage.beams_unreadable,
                compile_paths_empty: coverage.compile_paths_empty,
                complete: coverage.complete?
              }
            })
          else
            format(candidates, results, coverage)
          end
        )

        if candidates != [], do: exit({:shutdown, 1})
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

  defp format([], results, coverage) do
    "OK: no Oban review candidates without static callers or cron entries " <>
      "(#{length(results)} scanned). #{coverage_note(coverage)}"
  end

  defp format(candidates, results, coverage) do
    header =
      "WARNING: #{length(candidates)} Oban worker(s) with no static callers and not in cron " <>
        "(#{length(results)} scanned) are review candidates, not proven dead code. " <>
        "Dynamic dispatch, missing debug info, and runtime-only cron are false positives; " <>
        "review before deleting. #{coverage_note(coverage)}"

    lines = Enum.map(candidates, fn r -> "- #{r.worker}" end)
    Enum.join([header | lines], "\n")
  end

  defp coverage_note(%{complete?: true, beams_scanned: n}) do
    "Coverage: #{n} beam(s) scanned, debug info complete."
  end

  defp coverage_note(coverage) do
    "Coverage INCOMPLETE: #{coverage.beams_scanned} beam(s) scanned, " <>
      "#{coverage.beams_ok} ok, #{coverage.beams_missing_debug_info} missing debug info, " <>
      "#{coverage.beams_unreadable} unreadable" <>
      if(coverage.compile_paths_empty, do: ", compile paths empty.", else: ".")
  end
end
