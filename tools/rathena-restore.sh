#!/usr/bin/env bash
# Restore the ragnarok database and its matching operator configuration backup.
#
#   ./rathena restore --yes
#   ./rathena restore backups/ragnarok-20260101-120000.sql.gz.age --yes
#
# The wrapper sets RATHENA_RESTORE and RATHENA_RESTORE_CONFIRM for us.
#
# Defaults to the most recent backup. This DESTROYS the current database, so
# it refuses to run without the confirmation variable, refuses while the
# servers are up, and takes a safety dump of the current state first.
#
# devenv captures task stdout as JSON, so all output goes to stderr.
set -euo pipefail
cd "${DEVENV_ROOT:-/workspaces/rathena}"

say() { echo "$@" >&2; }
die() { say "$@"; exit 1; }

# --- pick the file ----------------------------------------------------------
OUTDIR="${RATHENA_BACKUP_DIR:-backups}"
FILE="${RATHENA_RESTORE:-}"

if [ -z "$FILE" ]; then
  FILE=$(ls -1t "$OUTDIR"/ragnarok-*.sql.gz "$OUTDIR"/ragnarok-*.sql.gz.age 2>/dev/null | head -1 || true)
  [ -n "$FILE" ] || die "no backups found in $OUTDIR/"
  say "using the most recent backup:"
fi

[ -f "$FILE" ] || die "no such file: $FILE"
say "  $FILE  ($(du -h "$FILE" | cut -f1), $(date -r "$FILE" '+%Y-%m-%d %H:%M'))"

case "$FILE" in
  *.sql.gz.age) STEM=${FILE%.sql.gz.age}; CONFIG_FILE="$STEM.config.tar.gz.age" ;;
  *.sql.gz)     STEM=${FILE%.sql.gz};     CONFIG_FILE="$STEM.config.tar.gz" ;;
  *) die "unsupported backup name: $FILE" ;;
esac
[ ! -f "$CONFIG_FILE" ] || say "  $CONFIG_FILE  (matching settings)"

# --- refuse to run against a live server ------------------------------------
# A dump replays DROP TABLE / CREATE TABLE; doing that underneath a running
# server corrupts its in-memory state and whatever it writes back afterwards.
# `|| true`: pgrep exits 1 when nothing matches, and pipefail would turn that
# into a fatal error under set -e
RUNNING=$(pgrep -f '^\./(login|char|map)-server$' | wc -l || true)
if [ "$RUNNING" -gt 0 ]; then
  die "$RUNNING rAthena server(s) still running - stop 'devenv up' first (MariaDB must stay up)"
fi

# --- require an explicit confirmation ---------------------------------------
if [ "${RATHENA_RESTORE_CONFIRM:-}" != "yes" ]; then
  say ""
  say "This REPLACES the current database with the contents of that file."
  say "Every account, character and item created since then is lost."
  say ""
  say "Re-run with:  ./rathena restore --yes"
  exit 1
fi

# --- connection -------------------------------------------------------------
STATE=${RATHENA_STATE_DIR:-${DEVENV_STATE:-$PWD/.devenv/state}}
conf() { cat conf/import/inter_conf.txt "$STATE/db_secret_conf.txt" \
              "$STATE/inter_runtime_conf.txt" 2>/dev/null | sed -n "s/^$1: //p" | tail -1; }

PORT=$(conf login_server_port)
MYSQL_PWD=$(conf login_server_pw)
export MYSQL_PWD
[ -n "$PORT" ] || die ".devenv/state/inter_runtime_conf.txt missing - is the database up?"

M="mariadb -h 127.0.0.1 -P $PORT -u ragnarok"
$M ragnarok -e "SELECT 1" >/dev/null 2>&1 || die "ragnarok database not reachable on 127.0.0.1:$PORT"

# --- safety dump ------------------------------------------------------------
# Restoring the wrong file is the most likely mistake here, so make it
# reversible before doing anything destructive.
SAFETY_STAMP=$(date +%Y%m%d-%H%M%S)
SAFETY="$OUTDIR/pre-restore-$SAFETY_STAMP.sql.gz"
SAFETY_CONFIG="$OUTDIR/pre-restore-$SAFETY_STAMP.config.tar.gz"
mkdir -p "$OUTDIR"
mariadb-dump -h 127.0.0.1 -P "$PORT" -u ragnarok --lock-tables --routines --events \
  --default-character-set=utf8mb4 ragnarok | gzip -9 > "$SAFETY"
CONFIG_PATHS=(conf/import conf/msg_conf/import db/import)
[ ! -f .env ] || CONFIG_PATHS+=(.env)
[ ! -f secrets.age ] || CONFIG_PATHS+=(secrets.age)
tar -czf "$SAFETY_CONFIG" -- "${CONFIG_PATHS[@]}"
say "current database saved to $SAFETY"
say "current settings saved to $SAFETY_CONFIG"

# --- restore ----------------------------------------------------------------
IDENT="$HOME/.config/secretspec/age-identity.txt"

case "$FILE" in
  *.age)
    [ -f "$IDENT" ] || die "$FILE is encrypted but no age identity at $IDENT"
    age -d -i "$IDENT" "$FILE" | gunzip -c | $M ragnarok
    ;;
  *)
    gunzip -c "$FILE" | $M ragnarok
    ;;
esac

# New backups have a matching settings archive. Old SQL-only backups remain
# supported and leave the current configuration untouched.
if [ -f "$CONFIG_FILE" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  case "$CONFIG_FILE" in
    *.age)
      [ -f "$IDENT" ] || die "$CONFIG_FILE is encrypted but no age identity at $IDENT"
      age -d -i "$IDENT" "$CONFIG_FILE" > "$TMP/settings.tar.gz"
      ;;
    *) cp "$CONFIG_FILE" "$TMP/settings.tar.gz" ;;
  esac

  # Refuse path traversal even though these archives are normally self-made.
  if tar -tzf "$TMP/settings.tar.gz" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    die "settings archive contains an unsafe path"
  fi
  mkdir "$TMP/settings"
  tar -xzf "$TMP/settings.tar.gz" -C "$TMP/settings"
  for dir in conf/import conf/msg_conf/import db/import; do
    [ ! -d "$TMP/settings/$dir" ] || {
      rm -rf "$dir"
      mkdir -p "${dir%/*}"
      cp -a "$TMP/settings/$dir" "$dir"
    }
  done
  [ ! -f "$TMP/settings/.env" ] || cp -a "$TMP/settings/.env" .env
  [ ! -f "$TMP/settings/secrets.age" ] || cp -a "$TMP/settings/secrets.age" secrets.age
  say "restored matching import settings and encrypted secrets"
else
  say "no matching settings archive; current settings kept (legacy backup)"
fi

TABLES=$($M ragnarok -sN -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ragnarok'")
ACCOUNTS=$($M ragnarok -sN -e "SELECT COUNT(*) FROM login")

say ""
say "restored: $TABLES tables, $ACCOUNTS account(s)"
say "start the servers with 'devenv up'."
say ""
say "to undo this restore:"
say "    RATHENA_RESTORE=$SAFETY RATHENA_RESTORE_CONFIRM=yes devenv tasks run rathena:restore"
