defmodule QueueKeeperCheck.DeadCodeTest do
  use ExUnit.Case, async: false

  alias QueueKeeperCheck.DeadCode

  test "scan with injected callers, cron and ignore" do
    results =
      DeadCode.scan(
        known: ["Demo.Abandoned", "Demo.Direct", "Demo.Cron", "Demo.Ignored"],
        callers: %{"Demo.Direct" => ["lib/enqueuer.ex"]},
        cron: ["Demo.Cron"],
        ignore: ["Demo.Ignored"],
        # skip discover so only `known` is considered
        apps: []
      )

    by = Map.new(results, &{&1.worker, &1})
    assert by["Demo.Direct"].status == :live
    assert by["Demo.Direct"].reason == :callers
    assert by["Demo.Cron"].status == :live
    assert by["Demo.Cron"].reason == :cron
    assert by["Demo.Abandoned"].status == :review_candidate
    refute Map.has_key?(by, "Demo.Ignored")

    assert DeadCode.review_candidates(
             known: ["Demo.Abandoned", "Demo.Direct", "Demo.Cron"],
             callers: %{"Demo.Direct" => ["lib/enqueuer.ex"]},
             cron: ["Demo.Cron"],
             apps: []
           ) == ["Demo.Abandoned"]

    # Compat alias
    assert DeadCode.dead_workers(
             known: ["Demo.Abandoned", "Demo.Direct", "Demo.Cron"],
             callers: %{"Demo.Direct" => ["lib/enqueuer.ex"]},
             cron: ["Demo.Cron"],
             apps: []
           ) == ["Demo.Abandoned"]
  end

  test "real beams: direct and worker: option are live; cron is live; dynamic and abandoned are review candidates" do
    Application.put_env(:queue_keeper_check, Oban,
      cron: [crontab: [{"0 * * * *", QueueKeeperCheck.DeadCodeCronWorker}]]
    )

    on_exit(fn -> Application.delete_env(:queue_keeper_check, Oban) end)

    results =
      DeadCode.scan(
        apps: [:queue_keeper_check],
        ignore: ["QueueKeeperCheck.DeadTestWorker"]
      )

    by = Map.new(results, &{&1.worker, &1})

    assert by["QueueKeeperCheck.DeadCodeDirectWorker"].status == :live
    assert by["QueueKeeperCheck.DeadCodeDirectWorker"].reason == :callers
    assert by["QueueKeeperCheck.DeadCodeViaOptsWorker"].status == :live
    assert by["QueueKeeperCheck.DeadCodeCronWorker"].status == :live
    assert by["QueueKeeperCheck.DeadCodeCronWorker"].reason == :cron

    # String-based Module.concat has no static module literal.
    assert by["QueueKeeperCheck.DeadCodeDynamicWorker"].status == :review_candidate
    assert by["QueueKeeperCheck.DeadCodeAbandonedWorker"].status == :review_candidate

    report =
      DeadCode.scan_report(
        apps: [:queue_keeper_check],
        ignore: ["QueueKeeperCheck.DeadTestWorker"]
      )

    assert report.coverage.complete?
    assert report.coverage.beams_scanned > 0
    assert report.coverage.beams_missing_debug_info == 0
    refute Enum.any?(report.workers, &(&1.status == :dead))
  end

  test "missing BEAM debug info is reported as incomplete coverage and can hide callers" do
    src = :code.which(QueueKeeperCheck.DeadCodeEnqueuer)
    assert is_list(src), "expected DeadCodeEnqueuer beam on the code path"

    tmp = Path.join(System.tmp_dir!(), "qk_nodebug_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    dest = Path.join(tmp, "Elixir.QueueKeeperCheck.DeadCodeEnqueuer.beam")
    # Read a copy first. :beam_lib.strip/1 on a filename strips in place and
    # would destroy the compiled test beam.
    {:ok, original} = File.read(List.to_string(src))
    {:ok, {_mod, stripped}} = :beam_lib.strip(original)
    File.write!(dest, stripped)

    report =
      DeadCode.scan_report(
        apps: [:queue_keeper_check],
        ignore: ["QueueKeeperCheck.DeadTestWorker"],
        beam_roots: [tmp]
      )

    refute report.coverage.complete?
    assert report.coverage.beams_missing_debug_info >= 1
    assert report.coverage.beams_scanned >= 1

    by = Map.new(report.workers, &{&1.worker, &1})

    # The only caller beam was stripped, so the statically-enqueued worker
    # becomes a review candidate rather than silently "dead" or staying live.
    assert by["QueueKeeperCheck.DeadCodeDirectWorker"].status == :review_candidate
    assert by["QueueKeeperCheck.DeadCodeDirectWorker"].reason == :no_call_sites
    assert by["QueueKeeperCheck.DeadCodeAbandonedWorker"].status == :review_candidate
  end

  test "full default scan does not discover UpdateBot because :queue_keeper_check is skipped" do
    report = DeadCode.scan_report(ignore: ["QueueKeeperCheck.DeadTestWorker"])
    names = Enum.map(report.workers, & &1.worker)
    refute "UpdateBot" in names
    refute "QueueKeeperCheck.UpdateBot" in names
    refute :queue_keeper_check in List.wrap(report.coverage.apps)
  end

  test "UpdateBot is found when its application is scanned explicitly" do
    report =
      DeadCode.scan_report(
        apps: [:queue_keeper_check],
        ignore: ["QueueKeeperCheck.DeadTestWorker"]
      )

    by = Map.new(report.workers, &{&1.worker, &1})
    assert by["UpdateBot"].status == :review_candidate
    assert by["QueueKeeperCheck.UpdateBot"].status == :review_candidate
    # Neither has a static caller in this project.
    assert by["UpdateBot"].reason == :no_call_sites
    assert by["QueueKeeperCheck.UpdateBot"].reason == :no_call_sites
  end

  test "UpdateBot is also found via --known / known: even if discover misses it" do
    assert DeadCode.review_candidates(
             apps: [],
             known: ["UpdateBot", "QueueKeeperCheck.UpdateBot"]
           ) == ["QueueKeeperCheck.UpdateBot", "UpdateBot"]
  end
end
