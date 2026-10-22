defmodule QueueKeeperCheck.Report do
  @moduledoc "Result of `QueueKeeperCheck.run/2`."
  @derive Jason.Encoder
  defstruct checked_at: nil, findings: [], status: :ok

  @type t :: %__MODULE__{
          checked_at: DateTime.t(),
          findings: [QueueKeeperCheck.Finding.t()],
          status: :ok | :warning | :critical
        }
end
