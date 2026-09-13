#!/usr/bin/env bash
# Recreate rAthena's ignored import directories from the upstream templates,
# then install this server's tracked overrides from conf/devenv/.
#
# The import directories are runtime output, just as they are upstream. Delete
# them whenever you want to simulate a fresh clone; the next `devenv up` runs
# this script before any rAthena server starts.
set -euo pipefail

SOURCE_ROOT=${DEVENV_ROOT:-/workspaces/rathena}
TARGET_ROOT=${RATHENA_IMPORT_ROOT:-$SOURCE_ROOT}
STATE=${DEVENV_STATE:-$TARGET_ROOT/.devenv/state}

copy_missing() {
  local source=$1 target=$2 file
  mkdir -p "$target"
  for file in "$source"/*; do
    [ -f "$file" ] || continue
    [ -e "$target/${file##*/}" ] || cp "$file" "$target/"
  done
}

copy_missing "$SOURCE_ROOT/conf/import-tmpl" "$TARGET_ROOT/conf/import"
copy_missing "$SOURCE_ROOT/conf/msg_conf/import-tmpl" "$TARGET_ROOT/conf/msg_conf/import"
copy_missing "$SOURCE_ROOT/db/import-tmpl" "$TARGET_ROOT/db/import"

# These dedicated devenv_*.txt files contain only generated infrastructure.
# Standard import files remain entirely operator-owned and are never
# overwritten here.
for source in "$SOURCE_ROOT"/conf/devenv/*; do
  [ -f "$source" ] || continue
  target="$TARGET_ROOT/conf/import/devenv_${source##*/}"
  if [ "${source##*/}" = inter_conf.txt ]; then
    sed "s|@DEVENV_STATE@|$STATE|g" "$source" > "$target"
    chmod 0644 "$target"
  else
    install -m 0644 "$source" "$target"
  fi
done
