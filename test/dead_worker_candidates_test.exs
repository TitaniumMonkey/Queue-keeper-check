defmodule QueueKeeperCheck.DeadWorkerCandidatesTest do
  use ExUnit.Case, async: true

  alias QueueKeeperCheck.DeadWorkerCandidates, as: Classify

  @now ~U[2026-11-10 12:00:00.000000Z]
  @window_days 7
  @window_secs 7 * 86_400

  defp attrs(overrides) do
    Map.merge(
      %{
        worker: "Demo.W",
        history_secs: 20 * 86_400,
        window_secs: @window_secs,
        window_days: @window_days,
        now: @now,
        last_inserted_at: DateTime.add(@now, -(@window_secs + 1), :second),
        pending_status: :ok,
        pending_count: 0,
        next_scheduled_at: nil,
        static: :unreferenced,
        static_reason: :no_call_sites,
        static_files: [],
        scan_complete?: true
      },
      overrides
    )
  end

  test "default window is 7 days (604800s)" do
    assert Classify.default_window_days() == 7
    assert Classify.window_seconds(7) == 604_800
    assert Classify.window_seconds(14) == 14 * 86_400
  end

  test "inclusive boundary: exactly 7 days is inactive; one second under is not" do
    exact = DateTime.add(@now, -@window_secs, :second)
    under = DateTime.add(@now, -(@window_secs - 1), :second)
    over = DateTime.add(@now, -(@window_secs + 1), :second)

    assert Classify.age(exact, @now) == @window_secs
    assert Classify.inactive?(exact, @now, @window_secs)
    refute Classify.inactive?(under, @now, @window_secs)
    assert Classify.inactive?(over, @now, @window_secs)
    assert Classify.inactive?(nil, @now, @window_secs)
  end

  test "both signals, sufficient history, no pending, complete scan: high confidence" do
    assert {:high_confidence, msg} = Classify.classify(attrs(%{}))
    assert msg =~ "Confidence: high"
    assert msg =~ "both signals agree"
    assert msg =~ "not proof the worker is dead"
    assert msg =~ "Dynamic dispatch"
  end

  test "inactivity alone is not high confidence when the worker is referenced in code or cron" do
    assert {:referenced, msg} =
             Classify.classify(
               attrs(%{static: :referenced, static_reason: :callers, static_files: ["lib/a.ex"]})
             )

    refute msg =~ "Confidence: high"
    assert msg =~ "not a high-confidence dead-worker candidate"
    assert msg =~ "application code"

    assert {:referenced, cron_msg} =
             Classify.classify(
               attrs(%{static: :referenced, static_reason: :cron, static_files: []})
             )

    assert cron_msg =~ "cron"
  end

  test "static signal alone (recent enqueue) is omitted" do
    recent = DateTime.add(@now, -60, :second)
    assert :omit = Classify.classify(attrs(%{last_inserted_at: recent}))
  end

  test "insufficient history is unknown, not proof of inactivity" do
    assert {:insufficient_history, msg} =
             Classify.classify(attrs(%{history_secs: 2 * 86_400}))

    assert msg =~ "unknown, not proof of inactivity"
    refute msg =~ "Confidence: high"
  end

  test "future-scheduled or pending jobs downgrade; old inserted_at is not proof" do
    next = DateTime.add(@now, 2 * 365 * 86_400, :second)

    assert {:pending_jobs, msg} =
             Classify.classify(attrs(%{pending_count: 1, next_scheduled_at: next}))

    assert msg =~ "future-scheduled"
    assert msg =~ "not proof those jobs are dead"
    refute msg =~ "Confidence: high"
  end

  test "pending-query error is unknown" do
    assert {:unknown, msg} = Classify.classify(attrs(%{pending_status: :error}))
    assert msg =~ "could not be queried"
    refute msg =~ "Confidence: high"
  end

  test "incomplete static analysis is not high confidence" do
    assert {:incomplete_analysis, msg} = Classify.classify(attrs(%{scan_complete?: false}))
    assert msg =~ "incomplete"
    refute msg =~ "Confidence: high"
  end

  test "a worker not in the scan is treated like unreferenced when the scan is complete" do
    assert {:high_confidence, msg} = Classify.classify(attrs(%{static: :not_in_scan}))
    assert msg =~ "not found as a compiled Oban.Worker"
  end

  test "never-inserted worker with sufficient history and no refs is high confidence" do
    assert {:high_confidence, msg} = Classify.classify(attrs(%{last_inserted_at: nil}))
    assert msg =~ "never inserted"
  end
end
