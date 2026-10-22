SELECT o0."queue", o0."worker", count(o0."id"), CAST(min(o0."attempted_at") AS TEXT) FROM "oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" <= ?)) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: ["2026-10-22T11:00:00.000000Z"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" <= ?)) AND ((o0."queue" = ?) AND (o0."worker" = ?)) LIMIT 10
  -- params: ["2026-10-22T11:00:00.000000Z", "default", "Demo.Orphan"]
SELECT o0."queue", o0."worker", count(o0."id"), CAST(min(o0."attempted_at") AS TEXT) FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > ?)) AND (o0."attempted_at" <= ?)) AND (NOT (o0."worker" IN (?))) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: ["2026-10-22T11:00:00.000000Z", "2026-10-22T11:54:59.000000Z", "Demo.Video"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > ?)) AND (o0."attempted_at" <= ?)) AND (NOT (o0."worker" IN (?))) AND ((o0."queue" = ?) AND (o0."worker" = ?)) LIMIT 10
  -- params: ["2026-10-22T11:00:00.000000Z", "2026-10-22T11:54:59.000000Z", "Demo.Video", "default", "Demo.Email"]
SELECT o0."queue", o0."worker", count(o0."id"), CAST(min(o0."attempted_at") AS TEXT) FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > ?)) AND (o0."attempted_at" <= ?)) AND (o0."worker" IN (?)) GROUP BY o0."queue", o0."worker" ORDER BY o0."queue", o0."worker"
  -- params: ["2026-10-22T11:00:00.000000Z", "2026-10-22T11:49:59.000000Z", "Demo.Video"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempted_at" > ?)) AND (o0."attempted_at" <= ?)) AND (o0."worker" IN (?)) AND ((o0."queue" = ?) AND (o0."worker" = ?)) LIMIT 10
  -- params: ["2026-10-22T11:00:00.000000Z", "2026-10-22T11:49:59.000000Z", "Demo.Video", "default", "Demo.Video"]
SELECT o0."queue", count(o0."id"), CAST(min(o0."scheduled_at") AS TEXT) FROM "oban_jobs" AS o0 WHERE ((o0."state" IN (SELECT value FROM JSON_EACH('["available","scheduled","retryable"]'))) AND ((o0."state" = 'available') OR (o0."scheduled_at" <= ?))) GROUP BY o0."queue" ORDER BY o0."queue"
  -- params: ["2026-10-22T12:00:00.000000Z"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" IN (SELECT value FROM JSON_EACH('["available","scheduled","retryable"]'))) AND ((o0."state" = 'available') OR (o0."scheduled_at" <= ?))) AND (o0."queue" = ?) LIMIT 10
  -- params: ["2026-10-22T12:00:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = 'executing') AND (o0."attempted_at" >= ?)) AND (o0."queue" = ?) LIMIT 1
  -- params: ["2026-10-22T11:59:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" IN (SELECT value FROM JSON_EACH('["scheduled","retryable"]'))) AND (o0."scheduled_at" >= ?)) AND (o0."attempted_at" >= ?)) AND (o0."queue" = ?) LIMIT 1
  -- params: ["2026-10-22T11:59:00.000000Z", "2026-10-22T11:59:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = 'discarded') AND (o0."discarded_at" >= ?)) AND (o0."queue" = ?) LIMIT 1
  -- params: ["2026-10-22T11:59:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = 'cancelled') AND (o0."cancelled_at" >= ?)) AND (o0."queue" = ?) LIMIT 1
  -- params: ["2026-10-22T11:59:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."scheduled_at" >= ?)) AND (o0."attempted_at" >= ?)) AND (o0."queue" = ?) LIMIT 1
  -- params: ["2026-10-22T10:45:00.000000Z", "2026-10-22T11:59:00.000000Z", "ghost"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" IN (SELECT value FROM JSON_EACH('["available","scheduled","retryable"]'))) AND ((o0."state" = 'available') OR (o0."scheduled_at" <= ?))) AND (o0."queue" = ?) LIMIT 10
  -- params: ["2026-10-22T12:00:00.000000Z", "ghost"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE (o0."state" = 'retryable') GROUP BY o0."worker", o0."queue"
  -- params: []
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= ?)) GROUP BY o0."worker", o0."queue"
  -- params: ["2026-10-22T11:55:00.000000Z"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'discarded') AND (o0."discarded_at" >= ?)) AND (o0."attempt" >= 2)) GROUP BY o0."worker", o0."queue"
  -- params: ["2026-10-22T11:55:00.000000Z"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'cancelled') AND (o0."cancelled_at" >= ?)) AND (o0."attempt" >= 2)) GROUP BY o0."worker", o0."queue"
  -- params: ["2026-10-22T11:55:00.000000Z"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= ?)) GROUP BY o0."worker", o0."queue"
  -- params: ["2026-10-22T11:55:00.000000Z"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (o0."state" = 'retryable') AND (o0."worker" = ?) LIMIT 10
  -- params: ["Demo.Flaky"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'executing') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= ?)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["2026-10-22T11:55:00.000000Z", "Demo.Flaky"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'discarded') AND (o0."discarded_at" >= ?)) AND (o0."attempt" >= 2)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["2026-10-22T11:55:00.000000Z", "Demo.Flaky"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'cancelled') AND (o0."cancelled_at" >= ?)) AND (o0."attempt" >= 2)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["2026-10-22T11:55:00.000000Z", "Demo.Flaky"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE (((o0."state" = 'completed') AND (o0."attempt" >= 2)) AND (o0."attempted_at" >= ?)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["2026-10-22T11:55:00.000000Z", "Demo.Flaky"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE ((o0."state" = ?) AND (o0."discarded_at" >= ?)) GROUP BY o0."worker", o0."queue"
  -- params: ["discarded", "2026-10-22T11:00:00.000000Z"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = ?) AND (o0."discarded_at" >= ?)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["discarded", "2026-10-22T11:00:00.000000Z", "Demo.Sync"]
SELECT o0."worker", o0."queue", count(o0."id") FROM "oban_jobs" AS o0 WHERE ((o0."state" = ?) AND (o0."cancelled_at" >= ?)) GROUP BY o0."worker", o0."queue"
  -- params: ["cancelled", "2026-10-22T11:00:00.000000Z"]
SELECT o0."id" FROM "oban_jobs" AS o0 WHERE ((o0."state" = ?) AND (o0."cancelled_at" >= ?)) AND (o0."worker" = ?) LIMIT 10
  -- params: ["cancelled", "2026-10-22T11:00:00.000000Z", "Demo.Hook"]
SELECT o0."worker", CAST(max(o0."inserted_at") AS TEXT), max(o0."id") FROM "oban_jobs" AS o0 WHERE (o0."worker" IN (?,?)) GROUP BY o0."worker"
  -- params: ["Demo.Hourly", "Demo.Never"]