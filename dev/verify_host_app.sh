#!/usr/bin/env bash
# End-to-end isolation check inside a real host app (dev/host_app: Repo + Oban with a
# queue, Cron and Pruner, and an Application.start/2 that prints HOST_APP_STARTED and
# inserts a job). Verifies that `mix queue_keeper.check` and `Release.main/2` in a real
# release (`bin/host_app eval`) do not start the app or Oban and do not write any row,
# and, with strace available, records every network connect and every file opened for
# writing during the release run.
#
#   dev/verify_host_app.sh                 # this checkout
#   QK_PATH=/path/to/other/checkout dev/verify_host_app.sh   # compare another version
#
# Needs Postgres on localhost (postgres/postgres). Creates/uses database qk_host_app.
set -uo pipefail
cd "$(dirname "$0")/host_app"
export PGPASSWORD=postgres
psql_() { psql -h localhost -U postgres -d qk_host_app -Atc "$1"; }

mix deps.get >/dev/null && mix compile >/dev/null 2>&1
mix ecto.create --quiet >/dev/null 2>&1; mix ecto.migrate --quiet >/dev/null 2>&1
psql_ "TRUNCATE oban_jobs, oban_peers"
psql_ "INSERT INTO oban_jobs (state, queue, worker, args, discarded_at, attempt) SELECT 'discarded', 'default', 'HostApp.Worker', '{}', now(), 1 FROM generate_series(1, 6)"
snapshot() { psql_ "SELECT (SELECT count(*) FROM oban_jobs) || ' jobs, ' || (SELECT count(*) FROM oban_peers) || ' peers, max(id)=' || (SELECT coalesce(max(id), 0) FROM oban_jobs)"; }

echo "== mix queue_keeper.check (QK_PATH=${QK_PATH:-../..})"
before=$(snapshot)
out=$(mix queue_keeper.check --repo HostApp.Repo 2>&1); code=$?
sleep 2
after=$(snapshot)
# only the report and the app-start marker (the host app logs every query at :debug)
echo "$out" | grep -E '^(OK|WARNING|CRITICAL|ERROR|- \[|HOST_APP_STARTED|usage)' | sed 's/^/   | /'
echo "exit code: $code"
echo "db before: $before"; echo "db after:  $after"
if grep -q HOST_APP_STARTED <<<"$out"; then echo "RESULT: host application WAS started"; else echo "RESULT: host application not started"; fi
[ "$before" == "$after" ] && echo "RESULT: no rows written" || echo "RESULT: ROWS CHANGED"

echo "== release: bin/host_app eval 'QueueKeeperCheck.Release.main(...)'"
MIX_ENV=prod mix release --overwrite --quiet >/dev/null 2>&1
REL=_build/prod/rel/host_app/bin/host_app
before=$(snapshot)
out=$($REL eval 'QueueKeeperCheck.Release.main(HostApp.Repo, otp_app: :host_app)' 2>&1); code=$?
after=$(snapshot)
echo "$out" | sed 's/^/   | /'
echo "exit code: $code"
echo "db before: $before"; echo "db after:  $after"
grep -q HOST_APP_STARTED <<<"$out" && echo "RESULT: host application WAS started" || echo "RESULT: host application not started"
[ "$before" == "$after" ] && echo "RESULT: no rows written" || echo "RESULT: ROWS CHANGED"

echo "== release: what is running after Release.check/2"
$REL eval '
  {_report, code} = QueueKeeperCheck.Release.check(HostApp.Repo, otp_app: :host_app)
  apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  IO.puts("exit code #{code}; started applications: #{inspect(apps)}")
  IO.puts("host_app started? #{:host_app in apps}; oban started? #{:oban in apps}")
  IO.puts("Oban.Registry process: #{inspect(Process.whereis(Oban.Registry))}")
  IO.puts("repo still running after check? #{inspect(Process.whereis(HostApp.Repo))}")
' 2>&1 | sed 's/^/   | /'

if command -v strace >/dev/null; then
  echo "== release under strace: network connects and files opened for writing"
  trace=$(mktemp)
  strace -f -qq -e trace=connect,openat -o "$trace" $REL eval 'QueueKeeperCheck.Release.main(HostApp.Repo, otp_app: :host_app, halt: false)' >/dev/null 2>&1
  echo "connect() targets (excluding AF_UNIX sockets of the local epmd-less runtime):"
  grep -o 'connect([0-9]*, {sa_family=AF_INET6\?[^}]*}' "$trace" | sed -E 's/connect\([0-9]+, //' | sort | uniq -c | sed 's/^/   /'
  echo "AF_UNIX connects:"; grep -o 'connect([0-9]*, {sa_family=AF_UNIX[^}]*}' "$trace" | sed -E 's/connect\([0-9]+, //' | sort | uniq -c | sed 's/^/   /'
  echo "files opened with O_WRONLY/O_RDWR/O_CREAT:"
  grep -E 'openat\(.*(O_WRONLY|O_RDWR|O_CREAT)' "$trace" | grep -v ENOENT | grep -oE '"[^"]+"' | sort | uniq -c | sed 's/^/   /'
  rm -f "$trace"
fi
