defmodule QueueKeeperCheck.Report do
  @moduledoc """
  Result of `QueueKeeperCheck.run/2`.

  * `:status` - `:ok`, `:warning`, `:critical`, or `:error` when at least one check could
    not complete (and no finding is critical). See `QueueKeeperCheck.Release.exit_code/1`.
  * `:findings` - `QueueKeeperCheck.Finding` structs
  * `:errors` - one map per check that failed: `%{check: atom | nil, error: String.t(),
    message: String.t()}`. `error` is the exception module; `message` is the first line of
    the exception message, truncated. Query parameters and connection options are never
    included.
  """
  @derive Jason.Encoder
  defstruct checked_at: nil, findings: [], errors: [], status: :ok

  @type error :: %{check: atom() | nil, error: String.t(), message: String.t()}

  @type t :: %__MODULE__{
          checked_at: DateTime.t(),
          findings: [QueueKeeperCheck.Finding.t()],
          errors: [error()],
          status: :ok | :warning | :critical | :error
        }

  @doc false
  def error(check, exception_or_exit) do
    {kind, message} =
      case exception_or_exit do
        %{__exception__: true} = e -> {inspect(e.__struct__), Exception.message(e)}
        {:exit, reason} -> {"exit", Exception.format_exit(reason)}
      end

    first_line = message |> String.split("\n", parts: 2) |> hd()

    first_line =
      if kind == "DBConnection.ConnectionError" and first_line =~ "dropped from queue",
        do:
          "no database connection became available (database unreachable, wrong " <>
            "credentials, or pool exhausted; the adapter logs the connect error)",
        else: first_line

    %{check: check, error: kind, message: String.slice(first_line, 0, 300)}
  end
end
