#!/usr/bin/env bash
# Restore the age identity that decrypts secrets.age, on a new machine.
#
#   ./rathena identity /path/to/age-identity.txt
#   pbpaste | ./rathena identity
#
# Verifies the key actually decrypts secrets.age before installing it, so a
# wrong key is caught now rather than at the next login attempt.
set -eu
cd "${DEVENV_ROOT:-/workspaces/rathena}"

IDENT="$HOME/.config/secretspec/age-identity.txt"
say() { echo "$@" >&2; }

if [ -f "$IDENT" ]; then
  say "an identity already exists at $IDENT"
  say "remove it first if you really mean to replace it"
  exit 1
fi

if [ -t 0 ]; then
  say "paste the age identity, then press Ctrl-D:"
fi

# Where did the key come from? When stdin is redirected from a file we can
# name it, so the operator is not left guessing which copy to clean up.
SRC=""
if [ ! -t 0 ] && [ -f /proc/self/fd/0 ]; then
  SRC=$(readlink -f /proc/self/fd/0 2>/dev/null || true)
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP"

if ! grep -q "AGE-SECRET-KEY-" "$TMP"; then
  say "that does not look like an age identity (no AGE-SECRET-KEY- line)"
  exit 1
fi

chmod 600 "$TMP"

# Prove it before installing it.
if [ -f secrets.age ]; then
  if ! SECRETSPEC_PROVIDER="age://secrets.age?identity=$TMP" \
       secretspec get RATHENA_HASH_PEPPER >/dev/null 2>&1; then
    say "this key does not decrypt secrets.age - not installing it"
    exit 1
  fi
  say "verified: it decrypts secrets.age"
fi

mkdir -p "$(dirname "$IDENT")"
cp "$TMP" "$IDENT"
chmod 600 "$IDENT"

say "installed $IDENT"
say "recipient: $(age-keygen -y "$IDENT" 2>/dev/null || echo '?')"

# Not deleted automatically: that file may be the operator's only backup,
# and destroying it would be unrecoverable.
if [ -n "$SRC" ] && [ "$SRC" != "$IDENT" ]; then
  say ""
  say "the key you fed in is still readable at:"
  say "    $SRC"
  say "if that was a temporary copy, remove it now:"
  say "    shred -u $SRC"
  say "if it is your backup, leave it alone."
fi

say ""
say "run 'devenv up' now."
