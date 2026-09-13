#!/usr/bin/env bash
# Set the group of an existing account.
#
#   ./rathena gm myname                 make it an Admin (group 99)
#   ./rathena gm helper --level 2       make it Support
#   ./rathena gm myname --level 0       take the powers away again
#
# Accounts are not created here. A player creates one by typing name_M at the
# login screen; this only moves an existing account between the groups defined
# in conf/groups.yml.
#
# Group membership is a column in the login table, so nothing about who holds
# it reaches git.
#
# The change applies at that account's next login. Someone already online
# keeps the group they logged in with.
set -euo pipefail
cd "${DEVENV_ROOT:-/workspaces/rathena}"

say() { echo "$@" >&2; }
die() { say "$@"; exit 1; }

STATE=${RATHENA_STATE_DIR:-${DEVENV_STATE:-$PWD/.devenv/state}}
conf() { cat conf/import/inter_conf.txt "$STATE/db_secret_conf.txt" \
              "$STATE/inter_runtime_conf.txt" 2>/dev/null | sed -n "s/^$1: //p" | tail -1; }

PORT=$(conf login_server_port)
MYSQL_PWD=$(conf login_server_pw)
export MYSQL_PWD
[ -n "$PORT" ] || die ".devenv/state/inter_runtime_conf.txt missing - MariaDB only runs while 'devenv up' does"

RA() { mariadb -h 127.0.0.1 -P "$PORT" -u ragnarok ragnarok "$@"; }
RA -e "SELECT 1" >/dev/null 2>&1 || die "ragnarok database not reachable on 127.0.0.1:$PORT"

group_name() {
  grep -A 3 -E "^[[:space:]]+- Id: $1[[:space:]]*$" conf/groups.yml \
    | sed -nE 's/^[[:space:]]+Name: (.*)$/\1/p' | head -1
}

list_groups() {
  say "  groups defined in conf/groups.yml:"
  grep -E "^[[:space:]]+- Id: |^[[:space:]]+Name: " conf/groups.yml | paste - - \
    | sed -E 's/^[[:space:]]*- Id: ([0-9]+)[[:space:]]+Name: (.*)$/    \1\t\2/' >&2
}

if [ $# -lt 1 ]; then
  say "usage: ./rathena gm <account> [--level N]"
  say ""
  list_groups
  exit 1
fi

user=$1; shift
level=99

while [ $# -gt 0 ]; do
  case "$1" in
    --level) level=${2:-}; shift 2 ;;
    *)       die "unknown option: $1" ;;
  esac
done

# Both are interpolated into SQL below.
case "$user" in
  *[!A-Za-z0-9_-]*) die "account names contain only letters, digits, _ and -: $user" ;;
esac
case "$level" in ""|*[!0-9]*) die "--level takes a whole number" ;; esac

CURRENT=$(RA -sN -e "SELECT group_id FROM login WHERE userid='$user';")

if [ -z "$CURRENT" ]; then
  say "no account named '$user'"
  say ""
  say "  accounts are created by registering: type '${user}_M' as the username"
  say "  at the login screen, with the password you want, then run this again"
  exit 1
fi

# Without a matching group the account gets powers nobody defined, and the
# map-server complains at every login.
if ! grep -qE "^[[:space:]]+- Id: $level[[:space:]]*$" conf/groups.yml conf/import/groups.yml 2>/dev/null; then
  say "no group with Id $level is defined"
  say ""
  list_groups
  exit 1
fi

if [ "$CURRENT" = "$level" ]; then
  name=$(group_name "$level")
  say "'$user' is already in group $level${name:+ ($name)}"
  exit 0
fi

RA -e "UPDATE login SET group_id=$level WHERE userid='$user';"

OLDNAME=$(group_name "$CURRENT")
NEWNAME=$(group_name "$level")
say "'$user': group $CURRENT${OLDNAME:+ ($OLDNAME)} -> $level${NEWNAME:+ ($NEWNAME)}"
say ""
say "Applies at the next login; an account already online keeps its old group."

if [ "$level" -ge 99 ]; then
  say ""
  say "Group 99 can do anything, including create items and read any account's"
  say "characters. Keep a separate ordinary account for playing."
fi
