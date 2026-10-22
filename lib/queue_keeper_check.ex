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
  * `:statement_timeout`, `:lock_timeout`, `:read_only` - safety limits, see
    `QueueKeeperCheck.Config` and `QueueKeeperCheck.Guard`

  Invalid options raise `ArgumentError`. Database errors never raise: each check runs on its
  own, and a check that fails (timeout, missing table or column, connection error) is
  reported in `report.errors` with status `:error` (unless a finding is `:critical`).
  After a connection error the remaining checks are skipped.
  """

  alias QueueKeeperCheck.{Checks, Config, Guard, Report}

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
    cfg = Config.build(opts)
    guard = Config.guard(opts)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    qopts = query_opts(repo, opts) ++ Guard.query_opts(guard)
    only = Keyword.get(opts, :only, @checks)

    {findings, errors} =
      case Guard.preflight(repo, guard) do
        :ok -> run_checks(repo, cfg, now, qopts, guard, only)
        {:error, e} -> {[], [Report.error(nil, e)]}
      end

    %Report{checked_at: now, findings: findings, errors: errors, status: status(findings, errors)}
  end

  defp run_checks(repo, cfg, now, qopts, guard, only) do
    {findings, errors} =
      Checks.with_memo(fn ->
        Enum.reduce(@checks, {[], []}, fn check, {findings, errors} ->
          cond do
            check not in only ->
              {findings, errors}

            Enum.any?(errors, &(&1.error == "DBConnection.ConnectionError")) ->
              skipped = %{
                check: check,
                error: "skipped",
                message: "skipped after a connection error"
              }

              {findings, [skipped | errors]}

            true ->
              case run_check(repo, check, cfg, now, qopts, guard) do
                {:ok, new} -> {findings ++ new, errors}
                {:error, error} -> {findings, [error | errors]}
              end
          end
        end)
      end)

    {findings, Enum.reverse(errors)}
  end

  defp run_check(repo, check, cfg, now, qopts, guard) do
    {:ok, Guard.run(repo, guard, fn -> apply(Checks, check, [repo, cfg, now, qopts]) end)}
  rescue
    e -> {:error, Report.error(check, e)}
  catch
    :exit, reason -> {:error, Report.error(check, {:exit, reason})}
  end

  # Postgres keeps oban_jobs in a schema ("public" by default). SQLite has no schemas and
  # MySQL treats a prefix as a database name, so only pass one when explicitly asked.
  defp query_opts(repo, opts) do
    case {Keyword.fetch(opts, :prefix), repo.__adapter__()} do
      {{:ok, prefix}, _} when prefix in [nil, false] -> []
      {{:ok, prefix}, _} -> [prefix: prefix]
      {:error, Ecto.Adapters.Postgres} -> [prefix: "public"]
      {:error, _other} -> []
    end
  end

  defp status(findings, errors) do
    cond do
      Enum.any?(findings, &(&1.severity == :critical)) -> :critical
      errors != [] -> :error
      findings != [] -> :warning
      true -> :ok
    end
  end

  @doc """
  Plain-text rendering, one line per finding or error. Queue and worker names come from
  the database, so control and invisible formatting characters (including newlines and
  bidirectional overrides) are replaced with `?`: a crafted name cannot forge extra lines
  or reorder text in a terminal or log.
  """
  def format(%Report{findings: [], errors: []} = r),
    do: "OK: no Oban queue problems found at #{DateTime.to_iso8601(r.checked_at)}"

  def format(%Report{} = r) do
    at = DateTime.to_iso8601(r.checked_at)

    header =
      case r.errors do
        [] ->
          "#{String.upcase(to_string(r.status))}: #{length(r.findings)} Oban queue problem(s) at #{at}"

        errors ->
          "#{String.upcase(to_string(r.status))}: #{length(r.findings)} Oban queue problem(s), " <>
            "#{length(errors)} check(s) could not run at #{at}"
      end

    lines =
      Enum.map(r.findings, fn f ->
        scope =
          [f.queue && "queue=#{f.queue}", f.worker && "worker=#{f.worker}"]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        "- [#{f.severity}] #{f.check} #{scope}: #{f.message} sample_ids=#{inspect(f.job_ids, charlists: :as_lists)}"
      end)

    error_lines =
      Enum.map(r.errors, fn e -> "- [error] #{e.check || "setup"}: #{e.error}: #{e.message}" end)

    Enum.join([header | Enum.map(lines ++ error_lines, &sanitize/1)], "\n")
  end

  # Cc = control characters (incl. \n, \r, ESC), Cf = format characters (incl. bidi
  # overrides U+202A-202E, U+2066-2069, zero-width characters).
  defp sanitize(line), do: String.replace(line, ~r/[\p{Cc}\p{Cf}]/u, "?")

  @doc """
  Build (but do not send) a Slack incoming-webhook payload. Post it with your own HTTP
  client, e.g. `Req.post!(webhook_url, json: QueueKeeperCheck.slack_payload(report))`.
  `&`, `<` and `>` are escaped as Slack requires, so a queue or worker name cannot
  inject `<!channel>` mentions or links.
  """
  def slack_payload(%Report{} = r) do
    text =
      r
      |> format()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    %{text: text}
  end
end
