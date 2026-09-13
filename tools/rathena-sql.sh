#!/usr/bin/env bash
# Open a SQL prompt on the ragnarok database, or run one statement.
#
#   ./rathena sql                                  interactive prompt
#   ./rathena sql "SELECT userid, group_id FROM login"
#   ./rathena sql < some-file.sql
#
# Finds the port and password itself: devenv allocates a free port at every
# start and writes it to $DEVENV_STATE/inter_runtime_conf.txt, and the password
# is generated into $DEVENV_STATE/db_secret_conf.txt, so neither can be
# hardcoded.
#
# Connects as 'ragnarok', which has rights on the ragnarok database only.
set -euo pipefail
cd "${DEVENV_ROOT:-/workspaces/rathena}"

die() { echo "$@" >&2; exit 1; }

STATE=${RATHENA_STATE_DIR:-${DEVENV_STATE:-$PWD/.devenv/state}}
conf() { cat conf/import/inter_conf.txt "$STATE/db_secret_conf.txt" \
              "$STATE/inter_runtime_conf.txt" 2>/dev/null | sed -n "s/^$1: //p" | tail -1; }

PORT=$(conf login_server_port)
# MYSQL_PWD rather than -p, which would show the password in `ps`
MYSQL_PWD=$(conf login_server_pw)
export MYSQL_PWD

[ -n "$PORT" ] || die ".devenv/state/inter_runtime_conf.txt missing - MariaDB only runs while 'devenv up' does"

if [ $# -gt 0 ]; then
  exec mariadb -h 127.0.0.1 -P "$PORT" -u ragnarok ragnarok -e "$*"
fi

exec mariadb -h 127.0.0.1 -P "$PORT" -u ragnarok ragnarok
