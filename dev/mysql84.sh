#!/usr/bin/env bash
# Local MySQL 8.4 LTS (x86_64 Linux) for the opt-in MySQL (Oban Dolphin) tests. No Docker, no root server.
#   dev/mysql84.sh install   # download the official generic Linux tarball (minimal) + libs
#   dev/mysql84.sh start     # init data dir on first run, start in background on 127.0.0.1:3307
#   dev/mysql84.sh stop | status | client [-e "select version()"]
# Server: root with no password, bound to 127.0.0.1 only. Files: ./.mysql (MYSQL_DIST, MYSQL_DATA).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${MYSQL_VERSION:-8.4.9}
DIST=${MYSQL_DIST:-$ROOT/.mysql/dist}
DATA=${MYSQL_DATA:-$ROOT/.mysql/data}
PORT=${MYSQL_PORT:-3307}
PKG=mysql-$VERSION-linux-glibc2.28-x86_64-minimal
BIN=$DIST/mysql/bin
CNF=$DIST/my.cnf
# Debian 13 renamed libaio.so.1 to libaio.so.1t64 (time_t transition); mysqld wants the old name.
export LD_LIBRARY_PATH=$DIST/compat-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

write_cnf() {
  mkdir -p "$DIST/run"
  cat > "$CNF" <<CNF
[mysqld]
basedir=$DIST/mysql
datadir=$DATA
socket=$DIST/run/mysql.sock
pid-file=$DIST/run/mysqld.pid
log-error=$DIST/run/mysqld.err
bind-address=127.0.0.1
port=$PORT
mysqlx=OFF
innodb_buffer_pool_size=128M
performance_schema=OFF
skip-log-bin
[client]
socket=$DIST/run/mysql.sock
host=127.0.0.1
port=$PORT
user=root
CNF
}

running() { [ -f "$DIST/run/mysqld.pid" ] && kill -0 "$(cat "$DIST/run/mysqld.pid")" 2>/dev/null; }

case "${1:-}" in
  install)
    # Debian/Ubuntu runtime libs; on other distros install libaio, libnuma and ncurses yourself.
    if command -v apt-get >/dev/null; then sudo apt-get install -y libaio1t64 libnuma1 libncurses6 >/dev/null; fi
    mkdir -p "$DIST/compat-lib" && cd "$DIST"
    [ -f "$PKG.tar.xz" ] || curl -fSLO "https://cdn.mysql.com/Downloads/MySQL-8.4/$PKG.tar.xz"
    [ -d "$PKG" ] || tar xf "$PKG.tar.xz"
    ln -sfn "$PKG" mysql
    for f in /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /lib/x86_64-linux-gnu/libaio.so.1t64; do
      [ -e "$f" ] && ln -sfn "$f" compat-lib/libaio.so.1 && break
    done
    "$BIN/mysqld" --version ;;
  start)
    write_cnf
    [ -d "$DATA/mysql" ] || "$BIN/mysqld" --defaults-file="$CNF" --initialize-insecure
    if running; then echo "already running on 127.0.0.1:$PORT"; exit 0; fi
    nohup "$BIN/mysqld" --defaults-file="$CNF" >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
      "$BIN/mysqladmin" --defaults-file="$CNF" ping >/dev/null 2>&1 && { echo "MySQL $VERSION up on 127.0.0.1:$PORT"; exit 0; }
      sleep 1
    done
    echo "MySQL failed to start; see $DIST/run/mysqld.err" >&2; exit 1 ;;
  stop)
    if ! running; then echo "not running"; exit 0; fi
    pid=$(cat "$DIST/run/mysqld.pid")
    "$BIN/mysqladmin" --defaults-file="$CNF" shutdown
    for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || { echo stopped; exit 0; }; sleep 1; done
    echo "mysqld (pid $pid) still running" >&2; exit 1 ;;
  status) running && echo "running (pid $(cat "$DIST/run/mysqld.pid")) on 127.0.0.1:$PORT" || { echo "not running"; exit 1; } ;;
  client) shift; exec "$BIN/mysql" --defaults-file="$CNF" "$@" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
