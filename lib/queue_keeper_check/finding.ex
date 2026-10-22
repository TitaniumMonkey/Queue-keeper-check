defmodule QueueKeeperCheck.Finding do
  @moduledoc """
  One detected problem.

  * `:check` - which check fired (see `QueueKeeperCheck.checks/0`)
  * `:severity` - `:warning` or `:critical`
  * `:queue` / `:worker` - scope of the finding (either may be `nil`)
  * `:count` - number of jobs involved
  * `:value` / `:threshold` - the measured value and the limit it crossed
  * `:message` - one human-readable line
  * `:job_ids` - up to 10 sample job ids for follow-up
  """
  @derive Jason.Encoder
  defstruct [
    :check,
    :severity,
    :queue,
    :worker,
    :count,
    :value,
    :threshold,
    :message,
    job_ids: []
  ]

  @type t :: %__MODULE__{
          check: atom(),
          severity: :warning | :critical,
          queue: String.t() | nil,
          worker: String.t() | nil,
          count: non_neg_integer(),
          value: number() | nil,
          threshold: number() | nil,
          message: String.t(),
          job_ids: [integer()]
        }
end
