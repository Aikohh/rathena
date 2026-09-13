#!/usr/bin/env bash
# Take one backup of the ragnarok database and operator import configuration.
#
#   ./rathena backup
#
# Live-safe: 67 of rAthena's 70 tables are MyISAM, which has no MVCC, so the
# tables are read-locked for the dump. That stalls writes for well under a
# second on a database this size.
#
# --lock-tables, not --lock-all-tables: the 'ragnarok' user has no global
# RELOAD privilege, and for a single-database dump the guarantee is equal.
# Never --single-transaction; it silently produces a torn MyISAM dump.
#
# Every SQL dump has a matching configuration archive containing conf/import,
# conf/msg_conf/import, db/import, .env and secrets.age when present. Generated
# DEVENV_STATE files are excluded: they are disposable and regenerate.
#
# Encrypts both files to an age RECIPIENT (a public key) when one is available,
# so backups can run unattended on a machine that holds no private key.
#
# devenv captures task stdout as JSON, so all output goes to stderr.
set -euo pipefail
cd "${DEVENV_ROOT:-/workspaces/rathena}"

say() { echo "$@" >&2; }

# --- connection -------------------------------------------------------------
# Same import chain rAthena itself resolves; the last definition wins.
STATE=${RATHENA_STATE_DIR:-${DEVENV_STATE:-$PWD/.devenv/state}}
conf() { cat conf/import/inter_conf.txt "$STATE/db_secret_conf.txt" \
              "$STATE/inter_runtime_conf.txt" 2>/dev/null | sed -n "s/^$1: //p" | tail -1; }

RA_PORT=$(conf login_server_port)
MYSQL_PWD=$(conf login_server_pw)
export MYSQL_PWD

if [ -z "$RA_PORT" ]; then
  say ".devenv/state/inter_runtime_conf.txt missing - run 'devenv up' first"
  exit 1
fi

if ! mariadb -h 127.0.0.1 -P "$RA_PORT" -u ragnarok ragnarok \
     -e "SELECT 1 FROM login LIMIT 1" >/dev/null 2>&1; then
  say "ragnarok database not reachable on 127.0.0.1:$RA_PORT"
  exit 1
fi

# --- destination ------------------------------------------------------------
OUTDIR="${RATHENA_BACKUP_DIR:-backups}"
mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$OUTDIR/ragnarok-$STAMP.sql.gz"
CONFIG_OUT="$OUTDIR/ragnarok-$STAMP.config.tar.gz"

RECIPIENT="${RATHENA_BACKUP_RECIPIENT:-}"
IDENT="$HOME/.config/secretspec/age-identity.txt"

if [ -z "$RECIPIENT" ] && [ -f "$IDENT" ]; then
  RECIPIENT=$(age-keygen -y "$IDENT" 2>/dev/null || true)
fi

if [ -n "$RECIPIENT" ]; then
  OUT="$OUT.age"
  CONFIG_OUT="$CONFIG_OUT.age"
fi
PUBLISHED=0
trap '[ "$PUBLISHED" = 1 ] || rm -f "$OUT" "$CONFIG_OUT"; rm -f "$OUT.part" "$CONFIG_OUT.part"' EXIT

# --- dump -------------------------------------------------------------------
if [ -n "$RECIPIENT" ]; then
  mariadb-dump -h 127.0.0.1 -P "$RA_PORT" -u ragnarok \
    --lock-tables --routines --events --default-character-set=utf8mb4 \
    ragnarok | gzip -9 | age -r "$RECIPIENT" > "$OUT.part"
else
  mariadb-dump -h 127.0.0.1 -P "$RA_PORT" -u ragnarok \
    --lock-tables --routines --events --default-character-set=utf8mb4 \
    ragnarok | gzip -9 > "$OUT.part"
fi

# Package every operator-owned import file beside the database dump. `tar`
# records relative paths, permissions and empty directories. .env is optional.
CONFIG_PATHS=(conf/import conf/msg_conf/import db/import)
[ ! -f .env ] || CONFIG_PATHS+=(.env)
[ ! -f secrets.age ] || CONFIG_PATHS+=(secrets.age)
if [ -n "$RECIPIENT" ]; then
  tar -czf - -- "${CONFIG_PATHS[@]}" | age -r "$RECIPIENT" > "$CONFIG_OUT.part"
else
  tar -czf "$CONFIG_OUT.part" -- "${CONFIG_PATHS[@]}"
fi

# Publish only a complete pair; pipefail above aborts before this on error.
mv "$OUT.part" "$OUT"
mv "$CONFIG_OUT.part" "$CONFIG_OUT"
PUBLISHED=1

# --- retention --------------------------------------------------------------
KEEP="${RATHENA_BACKUP_KEEP:-24}"
case "$KEEP" in ""|*[!0-9]*) KEEP=24 ;; esac
# `|| true`: ls exits non-zero when one of the two globs matches nothing, and
# pipefail would turn that into a silent early exit before the report below
while IFS= read -r old; do
  [ -n "$old" ] || continue
  case "$old" in
    *.sql.gz.age) stem=${old%.sql.gz.age}; config="$stem.config.tar.gz.age" ;;
    *.sql.gz)     stem=${old%.sql.gz};     config="$stem.config.tar.gz" ;;
  esac
  rm -f -- "$old" "$config"
done < <(ls -1t "$OUTDIR"/ragnarok-*.sql.gz "$OUTDIR"/ragnarok-*.sql.gz.age 2>/dev/null \
  | tail -n +$((KEEP + 1)) || true)

say "database backup: $OUT ($(du -h "$OUT" | cut -f1))"
say "settings backup: $CONFIG_OUT ($(du -h "$CONFIG_OUT" | cut -f1))"

if [ -n "$RECIPIENT" ]; then
  say "  encrypted to: $RECIPIENT"
  say "  restore:      ./rathena restore '$OUT' --yes"
else
  say "  NOT ENCRYPTED - database and settings are readable"
  say "  restore:      ./rathena restore '$OUT' --yes"
fi
