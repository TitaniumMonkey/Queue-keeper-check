defmodule QueueKeeperCheck.Release do
  @moduledoc """
  Run the check from a release, outside Oban, e.g. from system cron. `mix` isn't available
  in releases, so use `eval`, which loads code without starting your application (and
  therefore without starting Oban):

      bin/my_app eval 'QueueKeeperCheck.Release.main(MyApp.Repo, otp_app: :my_app)'

  `main/2` starts only the repo (pool of 2), prints the report and halts with exit status
  0 (ok), 1 (warning) or 2 (critical). Because it never depends on Oban running, it keeps
  working when Oban itself is down. Pair it with an outside heartbeat so you also hear
  when *this* stops running (see the README section "When Oban itself is down").

  Options are those of `QueueKeeperCheck.run/2`, plus `:otp_app` (to load the repo's
  config), `:json` (print JSON) and `:halt` (default `true`).
  """

  @doc "Run once and return `{report, exit_code}` without halting."
  def check(repo, opts \\ []) do
    {otp_app, opts} = Keyword.pop(opts, :otp_app)
    if otp_app, do: Application.load(otp_app)

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(adapter_app(repo.__adapter__()))

    case repo.start_link(pool_size: 2) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    report = QueueKeeperCheck.run(repo, Keyword.drop(opts, [:json, :halt]))
    {report, exit_code(report)}
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

  defp adapter_app(Ecto.Adapters.Postgres), do: :postgrex
  defp adapter_app(Ecto.Adapters.SQLite3), do: :ecto_sqlite3
  defp adapter_app(Ecto.Adapters.MyXQL), do: :myxql
  defp adapter_app(_other), do: :ecto_sql
end
