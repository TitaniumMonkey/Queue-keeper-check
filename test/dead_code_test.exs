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
    assert by["Demo.Abandoned"].status == :dead
    refute Map.has_key?(by, "Demo.Ignored")

    assert DeadCode.dead_workers(
             known: ["Demo.Abandoned", "Demo.Direct", "Demo.Cron"],
             callers: %{"Demo.Direct" => ["lib/enqueuer.ex"]},
             cron: ["Demo.Cron"],
             apps: []
           ) == ["Demo.Abandoned"]
  end

  test "real beams: direct and worker: option are live; cron is live; dynamic and abandoned are dead" do
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
    assert by["QueueKeeperCheck.DeadCodeDynamicWorker"].status == :dead
    assert by["QueueKeeperCheck.DeadCodeAbandonedWorker"].status == :dead
  end
end
