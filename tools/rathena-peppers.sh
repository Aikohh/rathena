#!/usr/bin/env bash
# Generate the two operator peppers once and store them in secrets.age.
#
# They are never rotated: the hash pepper is mixed into every stored password,
# so changing it invalidates every account. Existing values are therefore kept.
#
# devenv captures task stdout as JSON, so all output goes to stderr.
set -eu
cd "${DEVENV_ROOT:-/workspaces/rathena}"

IDENT="$HOME/.config/secretspec/age-identity.txt"
export SECRETSPEC_PROVIDER="${SECRETSPEC_PROVIDER:-age://secrets.age?identity=$IDENT}"

say() { echo "$@" >&2; }

if [ ! -f "$IDENT" ]; then
  say "no age identity at $IDENT"
  say "create one first:  age-keygen -o $IDENT"
  exit 1
fi

# 43 chars is ~256 bits of base62 for the hash pepper; the wire pepper is
# capped at 20 because that is the size of login_session_data::md5key, which
# is what actually reaches the client.
gen() { head -c 128 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

for spec in "RATHENA_HASH_PEPPER 43" "RATHENA_WIRE_PEPPER 20"; do
  name=${spec%% *}
  len=${spec##* }

  if secretspec get "$name" >/dev/null 2>&1; then
    say "  kept      $name (already set)"
    continue
  fi

  secretspec set "$name" "$(gen "$len")" >/dev/null 2>&1
  say "  generated $name ($len chars)"
done

say ""
say "Stored in gitignored secrets.age. Run './rathena backup' to archive it"
say "with the database and import settings."
say "BACK UP $IDENT SEPARATELY NOW."
say "Without that key the hash pepper is unrecoverable and every account"
say "would have to be reset with: ./rathena passwd <account>"
