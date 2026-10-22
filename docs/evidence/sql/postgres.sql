begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."queue", o0."worker", count(o0."id"), min(o0."attempted_at")::timestamp FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" <= $1)) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: [~U[2026-10-22 11:00:00.000000Z]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" <= $1)) AND ((o0."queue" = $2) AND (o0."worker" = $3)) LIMIT 10
  -- params: [~U[2026-10-22 11:00:00.000000Z], "default", "Demo.Orphan"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."queue", o0."worker", count(o0."id"), min(o0."attempted_at")::timestamp FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > $1)) AND (o0."attempted_at" <= $2)) AND (NOT (o0."worker" = ANY($3))) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: [~U[2026-10-22 11:00:00.000000Z], ~U[2026-10-22 11:54:59.000000Z], ["Demo.Video"]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > $1)) AND (o0."attempted_at" <= $2)) AND (NOT (o0."worker" = ANY($3))) AND ((o0."queue" = $4) AND (o0."worker" = $5)) LIMIT 10
  -- params: [~U[2026-10-22 11:00:00.000000Z], ~U[2026-10-22 11:54:59.000000Z], ["Demo.Video"], "default", "Demo.Email"]
SELECT o0."queue", o0."worker", count(o0."id"), min(o0."attempted_at")::timestamp FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > $1)) AND (o0."attempted_at" <= $2)) AND (o0."worker" = ANY($3)) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: [~U[2026-10-22 11:00:00.000000Z], ~U[2026-10-22 11:49:59.000000Z], ["Demo.Video"]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > $1)) AND (o0."attempted_at" <= $2)) AND (o0."worker" = ANY($3)) AND ((o0."queue" = $4) AND (o0."worker" = $5)) LIMIT 10
  -- params: [~U[2026-10-22 11:00:00.000000Z], ~U[2026-10-22 11:49:59.000000Z], ["Demo.Video"], "default", "Demo.Video"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."queue", count(o0."id"), min(o0."scheduled_at")::timestamp FROM "public"."oban_jobs" AS o0 WHERE (o0."state" IN ('available','scheduled','retryable') AND ((o0."state" = 'available') OR (o0."scheduled_at" <= $1))) GROUP BY o0."queue" ORDER BY o0."queue"
  -- params: [~U[2026-10-22 12:00:00.000000Z]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (o0."state" IN ('available','scheduled','retryable') AND ((o0."state" = 'available') OR (o0."scheduled_at" <= $1))) AND (o0."queue" = $2) LIMIT 10
  -- params: [~U[2026-10-22 12:00:00.000000Z], "ghost"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" >= $1)) AND (o0."queue" = $2) LIMIT 1
  -- params: [~U[2026-10-22 11:59:00.000000Z], "ghost"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" IN ('scheduled','retryable') AND (o0."scheduled_at" >= $1)) AND (o0."attempted_at" >= $2)) AND (o0."queue" = $3) LIMIT 1
  -- params: [~U[2026-10-22 11:59:00.000000Z], ~U[2026-10-22 11:59:00.000000Z], "ghost"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = 'discarded') AND (o0."discarded_at" >= $1)) AND (o0."queue" = $2) LIMIT 1
  -- params: [~U[2026-10-22 11:59:00.000000Z], "ghost"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = 'cancelled') AND (o0."cancelled_at" >= $1)) AND (o0."queue" = $2) LIMIT 1
  -- params: [~U[2026-10-22 11:59:00.000000Z], "ghost"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."scheduled_at" >= $1)) AND (o0."attempted_at" >= $2)) AND (o0."queue" = $3) LIMIT 1
  -- params: [~U[2026-10-22 10:45:00.000000Z], ~U[2026-10-22 11:59:00.000000Z], "ghost"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (o0."state" IN ('available','scheduled','retryable') AND ((o0."state" = 'available') OR (o0."scheduled_at" <= $1))) AND (o0."queue" = $2) LIMIT 10
  -- params: [~U[2026-10-22 12:00:00.000000Z], "ghost"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (o0."state" = 'retryable') GROUP BY o0."worker", o0."queue"
  -- params: []
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= $1)) GROUP BY o0."worker", o0."queue"
  -- params: [~U[2026-10-22 11:55:00.000000Z]]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'discarded') AND (o0."discarded_at" >= $1)) AND (o0."attempt" >= 2)) GROUP BY o0."worker", o0."queue"
  -- params: [~U[2026-10-22 11:55:00.000000Z]]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'cancelled') AND (o0."cancelled_at" >= $1)) AND (o0."attempt" >= 2)) GROUP BY o0."worker", o0."queue"
  -- params: [~U[2026-10-22 11:55:00.000000Z]]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= $1)) GROUP BY o0."worker", o0."queue"
  -- params: [~U[2026-10-22 11:55:00.000000Z]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (o0."state" = 'retryable') AND (o0."worker" = $1) LIMIT 10
  -- params: ["Demo.Flaky"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= $1)) AND (o0."worker" = $2) LIMIT 10
  -- params: [~U[2026-10-22 11:55:00.000000Z], "Demo.Flaky"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'discarded') AND (o0."discarded_at" >= $1)) AND (o0."attempt" >= 2)) AND (o0."worker" = $2) LIMIT 10
  -- params: [~U[2026-10-22 11:55:00.000000Z], "Demo.Flaky"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'cancelled') AND (o0."cancelled_at" >= $1)) AND (o0."attempt" >= 2)) AND (o0."worker" = $2) LIMIT 10
  -- params: [~U[2026-10-22 11:55:00.000000Z], "Demo.Flaky"]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= $1)) AND (o0."worker" = $2) LIMIT 10
  -- params: [~U[2026-10-22 11:55:00.000000Z], "Demo.Flaky"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = $1) AND (o0."discarded_at" >= $2)) GROUP BY o0."worker", o0."queue"
  -- params: ["discarded", ~U[2026-10-22 11:00:00.000000Z]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = $1) AND (o0."discarded_at" >= $2)) AND (o0."worker" = $3) LIMIT 10
  -- params: ["discarded", ~U[2026-10-22 11:00:00.000000Z], "Demo.Sync"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = $1) AND (o0."cancelled_at" >= $2)) GROUP BY o0."worker", o0."queue"
  -- params: ["cancelled", ~U[2026-10-22 11:00:00.000000Z]]
SELECT o0."id" FROM "public"."oban_jobs" AS o0 WHERE ((o0."state" = $1) AND (o0."cancelled_at" >= $2)) AND (o0."worker" = $3) LIMIT 10
  -- params: ["cancelled", ~U[2026-10-22 11:00:00.000000Z], "Demo.Hook"]
rollback
  -- params: []
begin
  -- params: []
SELECT set_config('transaction_read_only', 'on', true), set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), set_config('idle_in_transaction_session_timeout', $3, true)
  -- params: ["5000", "1000", "10000"]
SELECT o0."worker", max(o0."inserted_at")::timestamp, max(o0."id") FROM "public"."oban_jobs" AS o0 WHERE (o0."worker" = ANY($1)) GROUP BY o0."worker"
  -- params: [["Demo.Hourly", "Demo.Never"]]
rollback
  -- params: []