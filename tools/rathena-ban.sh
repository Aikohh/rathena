#!/usr/bin/env bash
# Manage the login-server's IP ban list.
#
#   ./rathena ban 198.51.100.7                  ban until lifted
#   ./rathena ban 198.51.100.0/24 --days 7      ban a range for a week
#   ./rathena ban 198.51.100.7 --reason "bot"
#   ./rathena unban 198.51.100.7
#   ./rathena bans                              list the active bans
#
# Ranges use the forms the login-server actually matches, which are whole
# octets only (src/login/ipban.cpp): 1.2.3.4, 1.2.3.*, 1.2.*.* and 1.*.*.*.
# A /24, /16 or /8 written in CIDR is translated to those; any other prefix
# length cannot be expressed and is refused rather than silently widened.
#
# This blocks new logins. It does not disconnect anyone already playing.
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
[ -n "$PORT" ] || die ".devenv/state/inter_runtime_conf.txt missing - is the database up?"

RA() { mariadb -h 127.0.0.1 -P "$PORT" -u ragnarok ragnarok "$@"; }
RA -e "SELECT 1" >/dev/null 2>&1 || die "ragnarok database not reachable on 127.0.0.1:$PORT"

# --- turn what the operator typed into a pattern the login-server matches ----
to_pattern() {
  local a="$1"
  case "$a" in
    */*)
      local net=${a%/*} bits=${a#*/}
      IFS=. read -r o1 o2 o3 o4 <<< "$net"
      case "$bits" in
        8)  printf '%s.*.*.*' "$o1" ;;
        16) printf '%s.%s.*.*' "$o1" "$o2" ;;
        24) printf '%s.%s.%s.*' "$o1" "$o2" "$o3" ;;
        32) printf '%s.%s.%s.%s' "$o1" "$o2" "$o3" "$o4" ;;
        *)  die "the login-server matches whole octets only: use /8, /16, /24 or /32, not /$bits" ;;
      esac
      ;;
    *) printf '%s' "$a" ;;
  esac
}

# Only digits, dots and stars reach the database. Everything here is
# interpolated into SQL, so anything else is rejected outright.
validate() {
  case "$1" in
    *[!0-9.*]*) die "not an address or range: $1" ;;
  esac
  printf '%s' "$1" | grep -qE '^([0-9]{1,3}|\*)\.([0-9]{1,3}|\*)\.([0-9]{1,3}|\*)\.([0-9]{1,3}|\*)$' \
    || die "not an address or range: $1"
}

cmd=${1:-list}; shift || true

case "$cmd" in
  add)
    [ $# -ge 1 ] || die "usage: ./rathena ban <ip|cidr> [--days N] [--reason TEXT]"
    target=$(to_pattern "$1"); shift
    validate "$target"

    days=""; reason="banned by the operator"
    while [ $# -gt 0 ]; do
      case "$1" in
        --days)   days=${2:-}; shift 2 ;;
        --reason) reason=${2:-}; shift 2 ;;
        *)        die "unknown option: $1" ;;
      esac
    done

    if [ -n "$days" ]; then
      case "$days" in ""|*[!0-9]*) die "--days takes a whole number of days" ;; esac
      until_sql="DATE_ADD(NOW(), INTERVAL $days DAY)"
      human="$days day(s)"
    else
      # The login-server only honours rows with rtime in the future, so
      # "forever" is a date far enough out to outlive the server.
      until_sql="'2099-12-31 23:59:59'"
      human="until lifted"
    fi

    # escape quotes and backslashes in the free-text reason
    reason=$(printf '%s' "$reason" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")

    RA -e "REPLACE INTO ipbanlist (list, btime, rtime, reason)
           VALUES ('$target', NOW(), $until_sql, '$reason');"
    say "banned $target ($human): $reason"
    say "  already-connected players are not disconnected"
    ;;

  remove)
    [ $# -ge 1 ] || die "usage: ./rathena unban <ip|cidr>"
    target=$(to_pattern "$1")
    validate "$target"
    before=$(RA -sN -e "SELECT COUNT(*) FROM ipbanlist WHERE list='$target';")
    RA -e "DELETE FROM ipbanlist WHERE list='$target';"
    if [ "$before" = "0" ]; then
      say "no ban on $target"
      say "  list the active ones with: ./rathena bans"
      exit 1
    fi
    say "unbanned $target"
    ;;

  list)
    n=$(RA -sN -e "SELECT COUNT(*) FROM ipbanlist WHERE rtime > NOW();")
    if [ "$n" = "0" ]; then
      say "no active bans"
    else
      say ""
      RA -e "SELECT list AS ip_or_range, btime AS banned_at, rtime AS expires, reason
             FROM ipbanlist WHERE rtime > NOW() ORDER BY btime DESC;"
      say ""
      say "$n active ban(s)"
    fi
    expired=$(RA -sN -e "SELECT COUNT(*) FROM ipbanlist WHERE rtime <= NOW();")
    [ "$expired" = "0" ] || say "$expired expired row(s) still stored; clear with: ./rathena bans --purge"
    ;;

  purge)
    RA -e "DELETE FROM ipbanlist WHERE rtime <= NOW();"
    say "expired bans cleared"
    ;;

  *)
    die "unknown ban command: $cmd"
    ;;
esac
