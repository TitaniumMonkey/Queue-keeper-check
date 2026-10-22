defmodule QueueKeeperCheck do
  @moduledoc """
  Read-only health check for Oban queues.

      report = QueueKeeperCheck.run(MyApp.Repo)
      IO.puts(QueueKeeperCheck.format(report))

  Detects eight conditions (see `checks/0` and `QueueKeeperCheck.Config` for thresholds):

  * `:orphaned` - jobs stuck in `executing` far longer than any job should run (dead node)
  * `:hanging` - jobs executing past their per-worker time budget
  * `:backlog` - too many due jobs, or the oldest due job waiting too long, per queue
  * `:stalled` - due jobs waiting and nothing in that queue attempted recently (queue stopped)
  * `:retry_storm` - many retrying/retried jobs for one worker in a short window
  * `:discarded` - spike of discarded jobs (silent failures)
  * `:cancelled` - spike of cancelled jobs
  * `:cron_missing` - an expected (cron) worker has had no job inserted for too long; opt-in
    via `cron_missing: [expected: %{"MyApp.Nightly" => 90_000}]`

  Options: any check name with a keyword list of thresholds, plus

  * `:prefix` - schema of `oban_jobs` (default `"public"` on Postgres, none on SQLite/MySQL)
  * `:now` - evaluation time (default `DateTime.utc_now/0`), handy in tests
  * `:only` - list of checks to run (default all)
  """

  alias QueueKeeperCheck.{Checks, Config, Report}

  @checks [
    :orphaned,
    :hanging,
    :backlog,
    :stalled,
    :retry_storm,
    :discarded,
    :cancelled,
    :cron_missing
  ]

  @doc "All check names, in the order they run."
  def checks, do: @checks

  @doc "Run the checks against `repo` and return a `QueueKeeperCheck.Report`."
  @spec run(module(), keyword()) :: Report.t()
  def run(repo, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cfg = Config.build(opts)
    qopts = query_opts(repo, opts)
    only = Keyword.get(opts, :only, @checks)

    findings =
      for check <- @checks,
          check in only,
          finding <- apply(Checks, check, [repo, cfg, now, qopts]),
          do: finding

    %Report{checked_at: now, findings: findings, status: status(findings)}
  end

  # Postgres keeps oban_jobs in a schema ("public" by default). SQLite has no schemas and
  # MySQL treats a prefix as a database name, so only pass one when explicitly asked.
  defp query_opts(repo, opts) do
    case {Keyword.fetch(opts, :prefix), repo.__adapter__()} do
      {{:ok, prefix}, _} -> [prefix: prefix]
      {:error, Ecto.Adapters.Postgres} -> [prefix: "public"]
      {:error, _other} -> []
    end
  end

  defp status(findings) do
    cond do
      Enum.any?(findings, &(&1.severity == :critical)) -> :critical
      findings != [] -> :warning
      true -> :ok
    end
  end

  @doc "Plain-text rendering, one line per finding."
  def format(%Report{findings: []} = r),
    do: "OK: no Oban queue problems found at #{DateTime.to_iso8601(r.checked_at)}"

  def format(%Report{} = r) do
    header =
      "#{String.upcase(to_string(r.status))}: #{length(r.findings)} Oban queue problem(s) at #{DateTime.to_iso8601(r.checked_at)}"

    lines =
      Enum.map(r.findings, fn f ->
        scope =
          [f.queue && "queue=#{f.queue}", f.worker && "worker=#{f.worker}"]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        "- [#{f.severity}] #{f.check} #{scope}: #{f.message} sample_ids=#{inspect(f.job_ids)}"
      end)

    Enum.join([header | lines], "\n")
  end

  @doc """
  Build (but do not send) a Slack incoming-webhook payload. Post it with your own HTTP
  client, e.g. `Req.post!(webhook_url, json: QueueKeeperCheck.slack_payload(report))`.
  """
  def slack_payload(%Report{} = r), do: %{text: format(r)}
end
