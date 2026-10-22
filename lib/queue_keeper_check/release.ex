defmodule QueueKeeperCheck.Release do
  @moduledoc """
  Run the check from a release, outside Oban, e.g. from system cron. `mix` isn't available
  in releases, so use `eval`, which loads code without starting your application (and
  therefore without starting Oban):

      bin/my_app eval 'QueueKeeperCheck.Release.main(MyApp.Repo, otp_app: :my_app)'

  `main/2` starts only the repo's adapter applications and the repo itself (pool of 1, or
  reuses it when it is already running), prints the report and halts with:

  | code | status |
  |---|---|
  | 0 | `:ok` |
  | 1 | `:warning` |
  | 2 | `:critical` |
  | 3 | `:error`: a check, the repo or the configuration failed, so the result is unknown |

  It never starts your application, Oban, or any process other than the repo (verified by
  `dev/verify_isolation.exs`), and stops the repo again when it started it. Because it never
  depends on Oban running, it keeps working when Oban itself is down. Pair it with an
  outside heartbeat so you also hear when *this* stops running (see the README section
  "When Oban itself is down").

  Options are those of `QueueKeeperCheck.run/2`, plus `:otp_app` (to load the repo's
  config), `:json` (print JSON) and `:halt` (default `true`).
  """

  alias QueueKeeperCheck.Report

  @doc """
  Run once and return `{report, exit_code}` without halting. Never raises: any failure
  (bad options, unknown repo, database down) becomes a report with status `:error` and
  exit code 3.
  """
  def check(repo, opts \\ []) do
    {otp_app, opts} = Keyword.pop(opts, :otp_app)
    opts = Keyword.drop(opts, [:json, :halt])

    try do
      if otp_app, do: Application.load(otp_app)
      ensure_repo!(repo)
      {:ok, _} = Application.ensure_all_started(:ecto_sql)
      {:ok, _} = Application.ensure_all_started(adapter_app(repo.__adapter__()))
      started = start_repo(repo)

      try do
        report = QueueKeeperCheck.run(repo, opts)
        {report, exit_code(report)}
      after
        if started, do: stop_repo(started)
      end
    rescue
      e -> {error_report(e), 3}
    catch
      :exit, reason -> {error_report({:exit, reason}), 3}
    end
  end

  @doc "Run once, print, and halt with the exit code (unless `halt: false`)."
  def main(repo, opts \\ []) do
    {report, code} = check(repo, opts)
    IO.puts(if opts[:json], do: Jason.encode!(report), else: QueueKeeperCheck.format(report))
    if Keyword.get(opts, :halt, true), do: System.halt(code), else: code
  end

  def exit_code(%{status: :ok}), do: 0
  def exit_code(%{status: :warning}), do: 1
  def exit_code(%{status: :critical}), do: 2
  def exit_code(%{status: :error}), do: 3

  defp ensure_repo!(repo) do
    unless is_atom(repo) and Code.ensure_loaded?(repo) and
             function_exported?(repo, :__adapter__, 0),
           do: raise(ArgumentError, "#{inspect(repo)} is not an Ecto repo module")
  end

  # Starts the repo unlinked (so a crash in it cannot take the caller down) with a pool of
  # one connection: the checks run one query at a time.
  defp start_repo(repo) do
    case repo.start_link(pool_size: 1) do
      {:ok, pid} ->
        Process.unlink(pid)
        pid

      {:error, {:already_started, _pid}} ->
        nil

      {:error, reason} ->
        exit({:repo_start_failed, reason})
    end
  end

  defp stop_repo(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end
  end

  defp error_report(e) do
    %Report{checked_at: DateTime.utc_now(), status: :error, errors: [Report.error(nil, e)]}
  end

  defp adapter_app(Ecto.Adapters.Postgres), do: :postgrex
  defp adapter_app(Ecto.Adapters.SQLite3), do: :ecto_sqlite3
  defp adapter_app(Ecto.Adapters.MyXQL), do: :myxql
  defp adapter_app(_other), do: :ecto_sql
end
