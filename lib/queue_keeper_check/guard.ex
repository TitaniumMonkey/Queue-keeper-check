defmodule QueueKeeperCheck.Guard do
  @moduledoc """
  Runs one check's queries under server-side safety limits.

  * **Postgres**: one transaction per check. Its first statement is

        SELECT set_config('transaction_read_only', 'on', true),
               set_config('statement_timeout', $1, true),
               set_config('lock_timeout', $2, true),
               set_config('idle_in_transaction_session_timeout', $3, true)

    (`transaction_read_only` only when `read_only: true`). All settings are
    transaction-local. The transaction is always rolled back, never committed. Because
    the settings would otherwise leak into a caller's transaction, calling
    `QueueKeeperCheck.run/2` inside an open transaction is refused.
  * **MySQL**: the connection is checked out for the duration of the check,
    `max_execution_time` (which applies to `SELECT` only) is set for the session and
    restored to its previous value afterwards. If the process dies mid-check, DBConnection
    disconnects that connection, so the setting cannot leak back into the pool. Read-only
    enforcement on MySQL comes from the database grants (see `docs/SECURITY_REVIEW.md`).
  * **SQLite**: no server-side settings exist; only the client-side timeout applies.

  Every engine also gets a client-side `:timeout` of `statement_timeout + 2000` ms on each
  query, so a query that the server does not cancel is abandoned by the client, and on
  Postgres and MySQL the whole check (one transaction / checkout) is limited to
  `check_timeout` ms.
  """

  @doc false
  def query_opts(guard), do: [timeout: guard[:statement_timeout] + 2_000]

  @doc "Run `fun` (which issues the check's queries) under the guard."
  def run(repo, guard, fun) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> postgres(repo, guard, fun)
      Ecto.Adapters.MyXQL -> mysql(repo, guard, fun)
      _ -> fun.()
    end
  end

  @doc """
  Checks that must pass before any query: on Postgres, refuse to run inside the caller's
  open transaction, where transaction-local settings (read-only, timeouts) would leak.
  """
  def preflight(repo, _guard) do
    if repo.__adapter__() == Ecto.Adapters.Postgres and repo.in_transaction?() do
      {:error,
       %ArgumentError{
         message:
           "QueueKeeperCheck must not run inside an open transaction (its transaction-local " <>
             "safety settings would apply to the caller's transaction)"
       }}
    else
      :ok
    end
  end

  defp postgres(repo, guard, fun) do
    timeout = guard[:statement_timeout]

    limits = [
      statement_timeout: timeout,
      lock_timeout: guard[:lock_timeout],
      idle_in_transaction_session_timeout: timeout * 2
    ]

    calls =
      for {{name, _ms}, i} <- Enum.with_index(limits, 1),
          do: "set_config('#{name}', $#{i}, true)"

    calls =
      if guard[:read_only],
        do: ["set_config('transaction_read_only', 'on', true)" | calls],
        else: calls

    sql = "SELECT " <> Enum.join(calls, ", ")
    params = for {_name, ms} <- limits, do: Integer.to_string(ms)

    result =
      repo.transaction(
        fn ->
          repo.query!(sql, params, query_opts(guard))
          repo.rollback({__MODULE__, fun.()})
        end,
        timeout: guard[:check_timeout]
      )

    case result do
      {:error, {__MODULE__, value}} -> value
    end
  end

  defp mysql(repo, guard, fun) do
    repo.checkout(
      fn ->
        %{rows: [[previous]]} =
          repo.query!("SELECT @@SESSION.max_execution_time", [], query_opts(guard))

        repo.query!(
          "SET SESSION max_execution_time = ?",
          [guard[:statement_timeout]],
          query_opts(guard)
        )

        try do
          fun.()
        after
          repo.query!("SET SESSION max_execution_time = ?", [previous], query_opts(guard))
        end
      end,
      timeout: guard[:check_timeout]
    )
  end
end
