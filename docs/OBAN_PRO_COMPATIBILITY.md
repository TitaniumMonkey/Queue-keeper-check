# Oban Pro compatibility

**Status: likely compatible, unverified, untested.** queue_keeper_check has never been run
against Oban Pro. Pro is distributed from a private package repository that requires a paid
license, which this project does not have, so there are no Pro tests in CI and none of the
statements below were checked against a running Pro system. Everything here comes from
reading Pro's *public* documentation (Pro v1.8.3 docs, read on 2026-10-22). Treat it as a
list of things to verify in your own pilot (see "Piloting safely" in the README), not as a
guarantee.

Some checks **could produce false results** under Pro. The cases we know of are listed
below.

## Why it should mostly work

* `Oban.Pro.Engine` (called `Oban.Pro.Engines.Smart` before Pro v1.8; the old name still
  works) is an `Oban.Engine` that "is responsible for all non-plugin database interaction,
  from inserting through executing jobs". Jobs live in the same `oban_jobs` table, with the
  same columns and states that queue_keeper_check reads (`state`, `queue`, `worker`,
  `attempt`, `scheduled_at`, `attempted_at`, `discarded_at`, `cancelled_at`, `inserted_at`).
  Pro adds its own tables (`oban_producers`, and in v1.8 `oban_pruners` and
  `oban_jobs_archive`), which queue_keeper_check does not read.
* Pro v1.7+ requires Oban 2.21+ and its v14 migration, which adds the `suspended` state
  (used for workflows and chains waiting on dependencies). queue_keeper_check ignores
  `suspended` jobs, which is the right thing: they are not due.
* All queries are plain `SELECT`s on `oban_jobs`, so the read-only and least-privilege
  guarantees in [SECURITY_REVIEW.md](SECURITY_REVIEW.md) do not depend on the engine.
* Pro v1.7 replaced several of Pro's own indexes and v1.8 dropped the old ones. The docs
  name Pro's indexes (unique, partition, workflow, chain, and Pro's old `cancelled_at` /
  `discarded_at` indexes); they do not say Oban core's indexes are changed. We have not
  verified that every core index queue_keeper_check relies on is still present on a Pro
  database; run `EXPLAIN` on the statements in SECURITY_REVIEW.md if query cost matters.

## Where it can be wrong under Pro

| Pro feature | Effect on queue_keeper_check |
|---|---|
| **Global limits and rate limits** (`global_limit`, `rate_limit` per queue) | Jobs deliberately held back by a limit stay `available` and age. `:backlog` can fire even though Pro is doing exactly what you configured, and `:stalled` can fire if the limit lets nothing start within the 60 s activity window (e.g. a slow rate limit). Raise `backlog` thresholds or exclude those queues. |
| **Pro Pruner** (`Oban.Pro.Pruner`, formerly `Oban.Pro.Plugins.DynamicPruner`) | Its default rule keeps only the **1,000 most recent** `completed`, `cancelled` or `discarded` jobs (by count, not age), and rules can differ per queue, worker or state. On a busy system that can be minutes of history, so `:discarded` and `:cancelled` spikes, `:retry_storm` with `include_completed: true` and `:stalled`'s look-back see less than their windows, and `:cron_missing` can report a worker whose last run was pruned. Configure an age-based rule that covers your windows, or shrink the windows. |
| **Archiving** (Pruner rules with `archive: true`) | Archived jobs move to `oban_jobs_archive`, which queue_keeper_check does not read. They count as pruned. |
| **Pro Lifeline** (`Oban.Pro.Lifeline`, formerly `DynamicLifeline`) | Rescues orphans using producer records rather than a fixed `rescue_after` age, so real orphans are usually rescued long before `:orphaned`'s 3600 s limit. Under Pro, `:orphaned` findings are more likely to be jobs that are genuinely still running. Lifeline also *discards* rescued jobs whose attempts are exhausted (unless `retry_exhausted` is set), which shows up in `:discarded`. |
| **DynamicPartitioner** (deprecated in Pro v1.8.1) | Replaces `oban_jobs` with a table partitioned by state (finished states sub-partitioned by date, kept 3 days by default) under the same name; the original is renamed `oban_jobs_old`. Queries should still run, but index shapes on the partitions were not verified, so query cost is unknown. Pro's documented way off partitioning runs a second Oban instance in another prefix, so during that transition run the checker once per prefix (`prefix:`). |
| **Snoozing** | Pro's engine records snooze information in `meta`. We did not verify whether Pro's snooze changes `attempt` the way Oban core's does (core rolls the attempt back), so a snoozing worker could inflate `:retry_storm` (which counts attempt >= 2 for some states). |
| **Async tracking** | Pro bundles job acknowledgements and records outcomes with a short lag (documented as up to about 5 ms). Negligible at whole-second resolution. |
| **Workflows, chains, batches** | Jobs waiting on dependencies are held in `suspended` (Pro v1.7+), ignored by the checker. How older Pro versions held such jobs was not checked. |
| **Multiple Oban instances / prefixes** | As with core Oban, one run checks one prefix. |

## Sources

All public documentation, read 2026-10-22:

* Pro engine: https://oban.pro/docs/pro/Oban.Pro.Engine.html
* Pro changelog (v1.8 renames, `oban_jobs_archive`, `oban_pruners`): https://oban.pro/docs/pro/changelog.html
* Upgrading to v1.7 (Oban v14 migration, `suspended`, index replacement): https://oban.pro/docs/pro/v1-7.html
* Upgrading to v1.8 (old indexes dropped, pruner rules, archive table): https://oban.pro/docs/pro/v1-8.html
* Pro Pruner (default 1,000 job retention, rules, archiving): https://oban.pro/docs/pro/Oban.Pro.Pruner.html
* DynamicPruner, Pro v1.6.0 (same 1,000 default before the rename): https://oban.pro/docs/pro/1.6.0/Oban.Pro.Plugins.DynamicPruner.html
* Pro Lifeline (producer-based rescue, exhausted jobs discarded): https://oban.pro/docs/pro/Oban.Pro.Lifeline.html
* DynamicPartitioner (deprecated, partitioned `oban_jobs`, migrating off): https://oban.pro/docs/pro/Oban.Pro.Plugins.DynamicPartitioner.html
* Adopting Pro: https://oban.pro/docs/pro/adoption.html
* Installation (licensed private package repository): https://oban.pro/docs/pro/installation.html

If you run Pro and try queue_keeper_check, an issue with what you saw (findings that were
wrong, query times, Pro and Oban versions) is the most useful contribution possible.
