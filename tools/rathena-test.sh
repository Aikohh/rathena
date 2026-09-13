#!/usr/bin/env bash
# Operator command test suite. Run with:
#
#   devenv test
#
# devenv starts MariaDB and the three servers, waits for them, runs this, then
# shuts everything down.
#
# Every test exercises a command an operator actually types. Tests that would
# outlive the run restore what they touched, so the suite is safe against a
# live server: rotated secrets are written back, configure's values are put
# back, and the accounts created here are deleted.
#
# RATHENA_TEST_DESTRUCTIVE=0 skips the restore round trip, which rewrites the
# whole database. Defaults to 1, because that is the command most worth
# knowing works before you need it.
set -uo pipefail
cd "${DEVENV_ROOT:-/workspaces/rathena}"

PASS=0; FAIL=0; SKIP=0
C_OK="\033[32m"; C_NO="\033[31m"; C_SKIP="\033[33m"; C_OFF="\033[0m"

ok()   { PASS=$((PASS+1)); printf "  ${C_OK}pass${C_OFF}  %s\n" "$1"; }
no()   { FAIL=$((FAIL+1)); printf "  ${C_NO}FAIL${C_OFF}  %s\n" "$1"; [ $# -gt 1 ] && printf "        %s\n" "$2"; }
skip() { SKIP=$((SKIP+1)); printf "  ${C_SKIP}skip${C_OFF}  %s\n" "$1"; }
group(){ printf "\n%s\n" "$1"; }

# assert the command succeeds
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d" "exit $? from: $*"; fi; }
# assert the command fails
tf() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d" "unexpectedly succeeded: $*"; else ok "$d"; fi; }
# assert captured text matches - use this instead of re-running a command,
# because the login-server bans an address after ddos_count (10) connections
# in ddos_interval (3s) and the ban lasts ddos_autoreset (10 minutes)
th() { local d="$1" pat="$2" txt="$3"
  if printf '%s' "$txt" | grep -qE -- "$pat"; then ok "$d"
  else no "$d" "no /$pat/ in: $(printf '%s' "$txt" | tail -2 | tr '\n' ' ')"; fi; }

# assert output matches, running the command once
tm() { local d="$1" pat="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if printf '%s' "$out" | grep -qE -- "$pat"; then ok "$d"
  else no "$d" "no /$pat/ in: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi; }

RA="bash rathena"
export RATHENA_NO_REEXEC=1   # devenv test already runs inside the environment

STATE=${RATHENA_STATE_DIR:-${DEVENV_STATE:-$PWD/.devenv/state}}
export RATHENA_STATE_DIR="$STATE"
conf() { cat conf/import/inter_conf.txt "$STATE/db_secret_conf.txt" \
              "$STATE/inter_runtime_conf.txt" 2>/dev/null | sed -n "s/^$1: //p" | tail -1; }
PORT=$(conf login_server_port)
export MYSQL_PWD; MYSQL_PWD=$(conf login_server_pw)
db() { mariadb -h 127.0.0.1 -P "$PORT" -u ragnarok ragnarok -sN -e "$1" 2>/dev/null; }

printf "\nrAthena operator command tests\n"

# devenv starts enterTest once the processes are up, but the map-server only
# listens after loading its 1265 maps. Without this the first port check races
# it and fails for a reason that has nothing to do with the command.
for _ in $(seq 1 60); do
  (exec 3<>/dev/tcp/127.0.0.1/5121) 2>/dev/null && break
  sleep 1
done

# --- restore anything these tests change ------------------------------------
SAVED=$(mktemp -d)
cp conf/import/secret_conf.txt "$SAVED/" 2>/dev/null
cp conf/import/deploy_conf.txt "$SAVED/" 2>/dev/null
# A failed-password test can leave 127.0.0.1 in ipbanlist, and the test
# database persists between runs, so the ban would silently break every later
# run's login tests.
db "DELETE FROM ipbanlist WHERE list LIKE '127.0.0.%'" >/dev/null 2>&1

cleanup() {
  cp "$SAVED/secret_conf.txt" conf/import/ 2>/dev/null
  cp "$SAVED/deploy_conf.txt" conf/import/ 2>/dev/null
  db "DELETE FROM login WHERE userid LIKE 'ratest%'" >/dev/null 2>&1
  db "DELETE FROM ipbanlist WHERE list LIKE '127.0.0.%'" >/dev/null 2>&1
  rm -rf "$SAVED"
}
trap cleanup EXIT

# --- 1. the wrapper itself --------------------------------------------------
group "wrapper"
HELP=$($RA help 2>&1)
for sub in configure passwd secrets restore backup check identity; do
  printf '%s' "$HELP" | grep -q "$sub" && ok "help lists '$sub'" || no "help lists '$sub'"
done
tf  "unknown subcommand is an error"    $RA notacommand
tm  "unknown subcommand names itself"   "notacommand"                $RA notacommand
t   "executable bit is set"             test -x rathena

# Documentation drift is silent: --enroll worked for several commits while
# being absent from the help text, so nobody would have found it. Every
# subcommand the wrapper dispatches has to appear in both places.
for sub in $(grep -oE "^  [a-z-]+\)" rathena | tr -d " )" | sort -u); do
  printf '%s' "$HELP" | grep -q "\b$sub\b" \
    && ok "help documents '$sub'" \
    || no "help documents '$sub'" "dispatched by ./rathena but not in its help"
  grep -q "\./rathena $sub\b" "$DEVENV_ROOT/devenv.nix" \
    || [ "$sub" = "up" ] \
    && ok "devenv.nix documents '$sub'" \
    || no "devenv.nix documents '$sub'" "not in the header reference"
done

# --- 1b. disposable import directories -------------------------------------
group "import generation"
[ -z "$(git ls-files 'conf/import/**' 'conf/msg_conf/import/**' 'db/import/**')" ] \
  && ok "upstream import directories are not tracked" \
  || no "upstream import directories are not tracked"
[ "$(git ls-files 'conf/devenv/**' | wc -l)" = "4" ] \
  && ok "four generated infrastructure templates are tracked" \
  || no "four generated infrastructure templates are tracked"

IMPORT_ROOT=$(mktemp -d)
mkdir -p "$IMPORT_ROOT/conf/import"
echo sentinel-secret > "$IMPORT_ROOT/conf/import/secret_conf.txt"
echo sentinel-battle > "$IMPORT_ROOT/conf/import/battle_conf.txt"
echo sentinel-groups > "$IMPORT_ROOT/conf/import/groups.yml"
RATHENA_IMPORT_ROOT="$IMPORT_ROOT" DEVENV_STATE="$IMPORT_ROOT/.devenv/state" \
  bash tools/rathena-imports.sh

t "upstream conf templates regenerate" \
  cmp conf/import-tmpl/atcommands.yml "$IMPORT_ROOT/conf/import/atcommands.yml"
t "upstream DB templates regenerate" \
  cmp db/import-tmpl/job_stats.yml "$IMPORT_ROOT/db/import/job_stats.yml"
grep -q "import: $IMPORT_ROOT/.devenv/state/db_secret_conf.txt" \
  "$IMPORT_ROOT/conf/import/devenv_inter_conf.txt" \
  && ok "generated DB config points at DEVENV_STATE" \
  || no "generated DB config points at DEVENV_STATE"
grep -qx sentinel-secret "$IMPORT_ROOT/conf/import/secret_conf.txt" \
  && ok "generation preserves runtime secrets" \
  || no "generation preserves runtime secrets"
grep -qx sentinel-battle "$IMPORT_ROOT/conf/import/battle_conf.txt" \
  && grep -qx sentinel-groups "$IMPORT_ROOT/conf/import/groups.yml" \
  && ok "generation preserves handwritten import settings" \
  || no "generation preserves handwritten import settings"

echo broken > "$IMPORT_ROOT/conf/import/devenv_inter_conf.txt"
RATHENA_IMPORT_ROOT="$IMPORT_ROOT" DEVENV_STATE="$IMPORT_ROOT/.devenv/state" \
  bash tools/rathena-imports.sh
grep -q "login_server_id: ragnarok" "$IMPORT_ROOT/conf/import/devenv_inter_conf.txt" \
  && ok "initialization repairs a replaced generated override" \
  || no "initialization repairs a replaced generated override"
rm -rf "$IMPORT_ROOT"

# --- 2. reachability --------------------------------------------------------
group "reachability"
PING=$($RA ping --local 2>&1)
th  "ping reports login-server"  "6900.*(open|OK)|(open|OK).*6900"  "$PING"
th  "ping reports char-server"   "6121.*(open|OK)|(open|OK).*6121"  "$PING"
th  "ping reports map-server"    "5121.*(open|OK)|(open|OK).*5121"  "$PING"
th  "ping names where the host came from" "loopback"  "$PING"

# ping defaults to the address the server advertises, so it checks what a
# player would actually connect to rather than always testing loopback
sleep 4   # each ping opens 3 sockets; ddos_count is 10 per ddos_interval (3s)
PING2=$($RA ping 2>&1)
th  "ping defaults to the advertised char_ip"  "advertised char_ip|127.0.0.1"  "$PING2"

# An unreachable WAN address must warn about NAT hairpinning rather than
# simply reporting the server down
PING3=$($RA ping 203.0.113.9 2>&1)
th  "ping warns about NAT hairpinning for a remote address" "hairpinning"  "$PING3"
th  "ping reports unreachable ports as failures"            "FAIL"         "$PING3"

# The whole point: ports can be open and the login accepted while the server
# still hands out an address no remote client can reach.
if db "SELECT 1" >/dev/null 2>&1; then
  db "DELETE FROM login WHERE userid='ratestping'" >/dev/null 2>&1
  db "INSERT INTO login (userid,user_pass,sex,email) VALUES ('ratestping','pingpass123','M','a@b.c')" >/dev/null 2>&1
  sleep 4
  PING4=$($RA ping localhost --account ratestping --password pingpass123 2>&1)
  th "ping completes a real login handshake"        "handshake: accepted"      "$PING4"
  th "ping reads the advertised char-server address" "advertised char-server"  "$PING4"
  th "ping fails when a remote host is handed a local char-server address" \
     "remote clients cannot reach that"  "$PING4"
  db "DELETE FROM login WHERE userid='ratestping'" >/dev/null 2>&1
else
  skip "ping handshake tests (no database)"
fi

# --- 3. pre-flight check ----------------------------------------------------
group "check"
sleep 4
CHECK=$($RA check 2>&1)
th  "check prints its report"    "pre-flight check"              "$CHECK"
th  "check counts failures"      "[0-9]+ failure"                "$CHECK"
th  "check verifies the interserver account was renamed" "interserver account renamed" "$CHECK"
th  "check verifies both secret files" "db_secret_conf.txt present, mode 600" "$CHECK"
th  "check verifies the listening ports" "login-server listening" "$CHECK"

# --- 4. secrets -------------------------------------------------------------
group "secrets"
BEFORE=$(sed -n 's/^passwd: //p' conf/import/secret_conf.txt | tail -1)
t   "secrets is idempotent without --rotate"  $RA secrets
AFTER=$(sed -n 's/^passwd: //p' conf/import/secret_conf.txt | tail -1)
[ "$BEFORE" = "$AFTER" ] && ok "secrets left the existing value alone" \
                         || no "secrets left the existing value alone" "changed without --rotate"
t   "secrets --rotate inter_pass"             $RA secrets --rotate inter_pass
ROTATED=$(sed -n 's/^passwd: //p' conf/import/secret_conf.txt | tail -1)
[ "$ROTATED" != "$BEFORE" ] && ok "--rotate changed the password" \
                            || no "--rotate changed the password" "value unchanged"
[ "$(stat -c %a conf/import/secret_conf.txt)" = "600" ] && ok "secret_conf.txt stays mode 600" \
                            || no "secret_conf.txt stays mode 600" "mode $(stat -c %a conf/import/secret_conf.txt)"
[ "${#ROTATED}" -le 23 ] && ok "generated password fits the 23-char interserver limit" \
                         || no "generated password fits the 23-char interserver limit" "${#ROTATED} chars"
cp "$SAVED/secret_conf.txt" conf/import/   # the running server holds the old one

# --- 5. configure -----------------------------------------------------------
group "configure"
CONFIGURED=$($RA configure --ip 198.51.100.9 --name RaTestName 2>&1)
[ $? -eq 0 ] && ok "configure --ip --name" \
             || no "configure --ip --name" "$(printf '%s' "$CONFIGURED" | tail -3)"
grep -q "char_ip: 198.51.100.9" conf/import/deploy_conf.txt && ok "configure wrote char_ip" \
                                        || no "configure wrote char_ip"
grep -q "map_ip: 198.51.100.9" conf/import/deploy_conf.txt && ok "configure wrote map_ip" \
                                        || no "configure wrote map_ip"
grep -q "server_name: RaTestName" conf/import/deploy_conf.txt && ok "configure wrote server_name" \
                                        || no "configure wrote server_name"
grep -q "char_ip: 127.0.0.1" conf/import/devenv_map_conf.txt && ok "generated map config keeps char_ip on loopback" \
                                        || no "generated map config keeps char_ip on loopback" "map-server would dial the WAN address"
printf '%s' "$CONFIGURED" | grep -qE 'passwd:|interserver :' \
  && no "configure does not print credentials" "credential field appeared in output" \
  || ok "configure does not print credentials"

tm  "configure reads RATHENA_PUBLIC_IP from the environment" "203.0.113.7" \
    env RATHENA_PUBLIC_IP=203.0.113.7 RATHENA_SERVER_NAME=RaEnv bash rathena configure

t   "configure accepts loopback for local testing" \
    $RA configure --ip 127.0.0.1 --name RaLocal
grep -q "char_ip: 127.0.0.1" conf/import/deploy_conf.txt \
  && ok "configure stores an explicit loopback address" \
  || no "configure stores an explicit loopback address"

# Configuring addresses must work before `devenv up` and on a stopped server.
# A temporary root with no runtime DB config or generated secrets proves that
# this is not accidentally passing because the test database is available.
NO_DB_ROOT=$(mktemp -d)
NO_DB_OUT=$(DEVENV_ROOT="$NO_DB_ROOT" RATHENA_PUBLIC_IP=203.0.113.8 \
  RATHENA_SERVER_NAME=NoDatabase python3 "$DEVENV_ROOT/tools/rathena-configure.py" 2>&1)
[ $? -eq 0 ] && ok "configure works without MariaDB or generated secrets" \
             || no "configure works without MariaDB or generated secrets" "$(printf '%s' "$NO_DB_OUT" | tail -3)"
grep -q "char_ip: 203.0.113.8" "$NO_DB_ROOT/conf/import/deploy_conf.txt" \
  && ok "configure writes deployment files before first start" \
  || no "configure writes deployment files before first start"
rm -rf "$NO_DB_ROOT"

# Do not contact an external service in the suite. Import the command module
# and replace only its detector so this tests the documented `auto` branch.
AUTO_ROOT=$(mktemp -d)
AUTO_OUT=$(DEVENV_ROOT="$AUTO_ROOT" RATHENA_PUBLIC_IP=auto \
  RATHENA_SERVER_NAME=AutoAddress python3 - <<'PY' 2>&1
import importlib.util
spec = importlib.util.spec_from_file_location("rathena_configure", "tools/rathena-configure.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.detect_public_ip = lambda: "203.0.113.10"
module.main()
PY
)
[ $? -eq 0 ] && ok "configure implements RATHENA_PUBLIC_IP=auto" \
             || no "configure implements RATHENA_PUBLIC_IP=auto" "$(printf '%s' "$AUTO_OUT" | tail -3)"
grep -q "char_ip: 203.0.113.10" "$AUTO_ROOT/conf/import/deploy_conf.txt" \
  && ok "configure stores the auto-detected address" \
  || no "configure stores the auto-detected address"
rm -rf "$AUTO_ROOT"

BAD_CONFIG=$(RATHENA_PUBLIC_IP=not-an-ip python3 tools/rathena-configure.py 2>&1)
[ $? -ne 0 ] && ok "configure rejects invalid input" || no "configure rejects invalid input"
th "configure reports invalid input without a traceback" "^error:" "$BAD_CONFIG"
printf '%s' "$BAD_CONFIG" | grep -q Traceback \
  && no "configure failure has no Python traceback" "$BAD_CONFIG" \
  || ok "configure failure has no Python traceback"

cp "$SAVED/deploy_conf.txt" conf/import/

# --- 6. accounts and passwords ---------------------------------------------
group "accounts"
db "DELETE FROM login WHERE userid LIKE 'ratest%'" >/dev/null 2>&1
db "INSERT INTO login (userid,user_pass,sex,email) VALUES ('ratest1','initialpw','M','a@b.c')" >/dev/null 2>&1
if [ "$(db "SELECT COUNT(*) FROM login WHERE userid='ratest1'")" = "1" ]; then
  tf "passwd rejects an unknown account"  $RA passwd nosuchaccount1234
  tm "passwd names the missing account"   "[Nn]o such account" $RA passwd nosuchaccount1234
  if printf 'brandnewpass\nbrandnewpass\n' | $RA passwd ratest1 >/dev/null 2>&1; then
    ok "passwd sets a password"
    TYPE=$(db "SELECT passwd_type FROM login WHERE userid='ratest1'")
    HASH=$(db "SELECT LEFT(user_pass,9) FROM login WHERE userid='ratest1'")
    [ "$HASH" = '$argon2id' ] && ok "passwd stores an argon2id hash" \
                              || no "passwd stores an argon2id hash" "got $HASH"
    [ $((TYPE & 1)) -eq 1 ]  && ok "passwd_type marks it hashed" \
                             || no "passwd_type marks it hashed" "type $TYPE"
    if grep -q "^password_hash_pepper:" conf/import/pepper_conf.txt 2>/dev/null; then
      [ $((TYPE & 16)) -eq 16 ] && ok "passwd applies the hash pepper" \
                                || no "passwd applies the hash pepper" "type $TYPE, pepper is configured"
    else
      skip "passwd applies the hash pepper (no pepper configured)"
    fi
  else
    no "passwd sets a password"
  fi
else
  skip "account tests (database not writable)"
fi

# --- 7. login protocol ------------------------------------------------------
group "login"
login_as() {
  local mode=${3:-auto}
  if [ "$mode" = auto ]; then
    if grep -q '^password_pepper:' conf/import/pepper_conf.txt 2>/dev/null; then
      mode=encrypted
    else
      mode=clear
    fi
  fi

  python3 - "$1" "$2" "$mode" <<'PY'
import hashlib,socket,struct,sys

def receive(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ConnectionError("server closed the connection")
        data += part
    return data

try:
    user, password, mode = sys.argv[1:]
    s=socket.create_connection(("127.0.0.1",6900),timeout=5)
    if mode == "encrypted":
        s.sendall(struct.pack("<H", 0x01db))
        header = receive(s, 4)
        opcode, length = struct.unpack("<HH", header)
        if opcode != 0x01dc or length < 4:
            raise ValueError(f"bad hash reply 0x{opcode:04x}/{length}")
        key = receive(s, length - 4)
        digest = hashlib.md5(key + password.encode()).digest()
        s.sendall(struct.pack("<HI24s16sB", 0x01dd, 20250716,
                  user.encode(), digest, 0x0a))
    elif mode == "sso":
        token = password.encode()
        fixed = struct.pack("<HHIB24s27s17s15s", 0x0825, 92 + len(token),
                20250716, 0x0a, user.encode(), b"", b"", b"")
        s.sendall(fixed + token)
    else:
        s.sendall(struct.pack("<HI24s24sB",0x0064,20250716,
                  user.encode(),password.encode(),0x0a))
    op=struct.unpack("<H",receive(s, 2))[0]
    s.close()
    sys.exit(0 if op in (0x0069,0x0ac4) else 1)
except Exception:
    sys.exit(2)
PY
}

# This suite fails passwords deliberately, and each failure counts toward
# ipban_dynamic_pass_failure_ban_limit (7 in 5 minutes) with the ban written to
# ipbanlist. Left alone it bans itself part-way through and every later login
# test fails for a reason that has nothing to do with what it is testing.
unban() { db "DELETE FROM ipbanlist WHERE list LIKE '127.0.0.%'" >/dev/null 2>&1; }

# The DDoS guard also closes repeat connections from one address, so space the
# attempts out rather than reporting a false failure.
login_retry() {
  local i
  for i in 1 2 3; do
    unban
    login_as "$1" "$2" && return 0
    sleep 3
  done
  return 1
}
# One attempt only. A refusal is deterministic, and repeating it trips
# dynamic_pass_failure_ban, which then blocks the registration tests below
# with a bare "refused" that looks like an unrelated failure.
login_refused() {
  unban
  login_as "$1" "$2"; local rc=$?
  unban   # do not let this deliberate failure count against later tests
  [ "$rc" = "1" ]
}
cleartext_refused() {
  unban
  login_as "$1" "$2" "${3:-clear}"; local rc=$?
  unban
  [ "$rc" = "1" ]
}
# A rejected connection and a DDoS ban look identical from the client side, so
# name the ban explicitly rather than reporting a misleading failure.
banned() { grep -q "DDoS Attack detected" "$DEVENV_STATE/../test-state/logs"/*.log 2>/dev/null; }

sleep 4
if ! db "SELECT 1" >/dev/null 2>&1; then
  skip "login protocol tests (no database)"
elif ! login_retry ratest1 brandnewpass; then
  skip "login protocol tests (login-server not accepting connections from 127.0.0.1)"
elif db "SELECT 1" >/dev/null 2>&1; then
  ok "the password set by ./rathena passwd logs in"
  t  "the wrong password is refused"                  login_refused ratest1 wrongpassword
  if grep -q "^new_account: yes" conf/import/login_conf.txt 2>/dev/null; then
    unban
    login_retry ratest2_M selfregpass >/dev/null 2>&1
    [ "$(db "SELECT COUNT(*) FROM login WHERE userid='ratest2'")" = "1" ] \
      && ok "_M self-registration creates the account" \
      || no "_M self-registration creates the account"
    t "a self-registered account can log in"          login_retry ratest2 selfregpass
    RT=$(db "SELECT passwd_type FROM login WHERE userid='ratest2'")
    [ -n "$RT" ] && [ $((RT & 1)) -eq 1 ] \
      && ok "a self-registered password is hashed, not stored in clear" \
      || no "a self-registered password is hashed, not stored in clear" "type ${RT:-none}"
  else
    skip "self-registration tests (new_account: no)"
  fi

  if grep -q '^password_pepper:' conf/import/pepper_conf.txt 2>/dev/null; then
    # A legacy row is deliberate: the old implementation rejected cleartext
    # only after an account had already been reset into passwd_type 3. This
    # proves the server-wide policy cannot be bypassed through an older row.
    db "DELETE FROM login WHERE userid='ratestwire'" >/dev/null 2>&1
    db "INSERT INTO login (userid,user_pass,sex,email,passwd_type) VALUES ('ratestwire','wirepass123','M','a@b.c',0)" >/dev/null 2>&1
    sleep 4
    t "wire-pepper mode rejects a correct cleartext login" \
      cleartext_refused ratestwire wirepass123
    t "wire-pepper mode rejects the launcher's pseudo-SSO packet" \
      cleartext_refused ratestwire wirepass123 sso
    sleep 4
    t "wire-pepper mode accepts the encrypted login" \
      login_retry ratestwire wirepass123

    # argon2id made from a cleartext password cannot verify the digest an
    # encrypted client sends. Give the audit one such row to find.
    db "DELETE FROM login WHERE userid='ratestwireold'" >/dev/null 2>&1
    db "INSERT INTO login (userid,user_pass,sex,email,passwd_type)
        SELECT 'ratestwireold',user_pass,'M','a@b.c',((passwd_type & 16) | 1)
        FROM login WHERE account_id=1" >/dev/null 2>&1
    th "check identifies accounts that need wire-password migration" \
      "cannot use required <passwordencrypt>:.*ratestwireold" "$($RA check 2>&1)"
    db "DELETE FROM login WHERE userid IN ('ratestwire','ratestwireold')" >/dev/null 2>&1
  else
    skip "wire-pepper enforcement tests (wire pepper disabled)"
  fi
fi

# --- 7b. password enrollment ------------------------------------------------
group "password enrollment"
if db "SELECT 1" >/dev/null 2>&1; then
  db "DELETE FROM login WHERE userid='ratest3'" >/dev/null 2>&1
  db "INSERT INTO login (userid,user_pass,sex,email) VALUES ('ratest3','originalpw','M','a@b.c')" >/dev/null 2>&1

  tm "passwd --enroll flags the account"  "next login"  $RA passwd ratest3 --enroll
  FLAG=$(db "SELECT passwd_type & 32 FROM login WHERE userid='ratest3'")
  [ "$FLAG" = "32" ] && ok "the enroll flag is stored (0x20)" \
                     || no "the enroll flag is stored (0x20)" "got ${FLAG:-none}"

  sleep 4
  if login_retry ratest3 ownchosenpw; then
    ok "the owner's next login sets the password"
    HASH=$(db "SELECT LEFT(user_pass,9) FROM login WHERE userid='ratest3'")
    [ "$HASH" = '$argon2id' ] && ok "the enrolled password is stored as argon2id" \
                              || no "the enrolled password is stored as argon2id" "got $HASH"
    LEFT=$(db "SELECT passwd_type & 32 FROM login WHERE userid='ratest3'")
    [ "$LEFT" = "0" ] && ok "enrollment is single-use: the flag is cleared" \
                      || no "enrollment is single-use: the flag is cleared" "flag still $LEFT"
    sleep 4
    t  "the enrolled password logs in afterwards"  login_retry ratest3 ownchosenpw
    sleep 4
    t  "the password it replaced no longer works"  login_refused ratest3 originalpw
  else
    no "the owner's next login sets the password"
  fi

  # A refused cleartext attempt must leave the flag up, or one typo would
  # strand the player with an account nobody knows the password to. An
  # encrypted client sends only a fixed-length digest, so the server cannot
  # infer or enforce the original password length in wire-pepper mode.
  sleep 4
  $RA passwd ratest3 --enroll >/dev/null 2>&1
  if grep -q '^password_pepper:' conf/import/pepper_conf.txt 2>/dev/null; then
    skip "short enrollment password check (encrypted client hides its length)"
  else
    unban
    login_as ratest3 ab >/dev/null 2>&1
    unban
    SHORT=$(db "SELECT passwd_type & 32 FROM login WHERE userid='ratest3'")
    [ "$SHORT" = "32" ] && ok "a too-short password is refused and the flag stays up" \
                        || no "a too-short password is refused and the flag stays up" "flag $SHORT"
  fi

  tm "passwd --cancel-enroll reports the cancellation" "cancelled" \
     $RA passwd ratest3 --cancel-enroll
  CLEARED=$(db "SELECT passwd_type & 32 FROM login WHERE userid='ratest3'")
  [ "$CLEARED" = "0" ] && ok "--cancel-enroll clears the flag" \
                       || no "--cancel-enroll clears the flag" "flag $CLEARED"
  sleep 4
  t  "--cancel-enroll leaves the existing password working"  login_retry ratest3 ownchosenpw

  tf "passwd --enroll rejects an unknown account"  $RA passwd nosuchaccount1234 --enroll
  tf "passwd rejects an unknown option"            $RA passwd ratest3 --nonsense

  th "check warns while an enrollment is pending" "waiting for a new password" \
     "$($RA passwd ratest3 --enroll >/dev/null 2>&1; $RA check 2>&1)"
  $RA passwd ratest3 --cancel-enroll >/dev/null 2>&1
  db "DELETE FROM login WHERE userid='ratest3'" >/dev/null 2>&1
else
  skip "password enrollment tests (no database)"
fi

# --- 7b2. sql access --------------------------------------------------------
group "sql"
if db "SELECT 1" >/dev/null 2>&1; then
  th "sql runs a statement"          "sPFatu8amDYk|userid"  "$($RA sql 'SELECT userid FROM login' 2>&1)"
  th "sql reads from stdin"          "[0-9]"                "$(printf 'SELECT COUNT(*) FROM login;\n' | $RA sql 2>&1)"

  # the port changes at every start, so it has to come from the config
  th "sql finds the port itself"     "userid"               "$($RA sql 'SELECT userid FROM login LIMIT 1' 2>&1)"

  db "DELETE FROM login WHERE userid='ratestsql'" >/dev/null 2>&1
  db "INSERT INTO login (userid,user_pass,sex,email,group_id) VALUES ('ratestsql','pw','M','a@b.c',0)" >/dev/null 2>&1
  $RA sql "UPDATE login SET group_id=99 WHERE userid='ratestsql'" >/dev/null 2>&1
  G=$(db "SELECT group_id FROM login WHERE userid='ratestsql'")
  [ "$G" = "99" ] && ok "sql can write, not only read" \
                  || no "sql can write, not only read" "group_id ${G:-none}"

  # the ragnarok user is scoped to its own database
  $RA sql "CREATE DATABASE ratest_should_fail" >/dev/null 2>&1 \
    && no "sql cannot reach other databases" "created one" \
    || ok "sql cannot reach other databases"

  db "DELETE FROM login WHERE userid='ratestsql'" >/dev/null 2>&1
else
  skip "sql tests (no database)"
fi

# --- 7b3. account groups ----------------------------------------------------
group "account groups"
if db "SELECT 1" >/dev/null 2>&1; then
  db "DELETE FROM login WHERE userid LIKE 'ratestgm%'" >/dev/null 2>&1
  db "INSERT INTO login (userid,user_pass,sex,email,group_id) VALUES ('ratestgm','pw','M','a@b.c',0)" >/dev/null 2>&1

  OUT=$($RA gm ratestgm 2>&1)
  th "gm promotes to group 99"          "group 0 \(Player\) -> 99 \(Admin\)"  "$OUT"
  th "gm says when the change applies"  "next login"                           "$OUT"
  th "gm warns about group 99"          "Group 99 can do anything"             "$OUT"
  GRP=$(db "SELECT group_id FROM login WHERE userid='ratestgm'")
  [ "$GRP" = "99" ] && ok "group_id is 99 in the database" \
                    || no "group_id is 99 in the database" "got ${GRP:-none}"

  th "gm --level demotes"  "99 \(Admin\) -> 0 \(Player\)"  "$($RA gm ratestgm --level 0 2>&1)"
  GRP=$(db "SELECT group_id FROM login WHERE userid='ratestgm'")
  [ "$GRP" = "0" ] && ok "the demotion is stored" || no "the demotion is stored" "got ${GRP:-none}"

  th "gm is idempotent"                 "already in group 0"  "$($RA gm ratestgm --level 0 2>&1)"
  th "gm accepts an intermediate group" "-> 2 \(Support\)"    "$($RA gm ratestgm --level 2 2>&1)"

  grep -q "ratestgm" conf/import/groups.yml 2>/dev/null \
    && no "the account name is not written into groups.yml" \
    || ok "the account name is not written into groups.yml"

  OUT=$($RA gm ratestnosuch 2>&1)
  th "gm reports an account that does not exist"  "no account named"  "$OUT"
  th "gm explains how accounts are created"       "_M"                "$OUT"

  OUT=$($RA gm ratestgm --level 42 2>&1)
  th "gm refuses an undefined group"   "no group with Id 42"  "$OUT"
  th "gm lists the groups that exist"  "99"                   "$OUT"
  GRP=$(db "SELECT group_id FROM login WHERE userid='ratestgm'")
  [ "$GRP" = "2" ] && ok "a refused group leaves the account unchanged" \
                   || no "a refused group leaves the account unchanged" "got ${GRP:-none}"

  tf "gm refuses SQL punctuation in the name"  env RATHENA_X=1 bash rathena gm "bad;name"
  tf "gm refuses a non-numeric level"          env RATHENA_X=1 bash rathena gm ratestgm --level abc
  [ "$(db "SELECT COUNT(*) FROM login")" -gt 0 ] && ok "the login table survived that" \
                                                 || no "the login table survived that"

  db "DELETE FROM login WHERE userid LIKE 'ratestgm%'" >/dev/null 2>&1
else
  skip "account group tests (no database)"
fi

# --- 7c. ip bans ------------------------------------------------------------
group "ip bans"
if db "SELECT 1" >/dev/null 2>&1; then
  db "DELETE FROM ipbanlist WHERE list LIKE '198.51.100%' OR list LIKE '203.0.113%'" >/dev/null 2>&1

  tm "ban stores a single address"    "banned 198.51.100.7"   $RA ban 198.51.100.7 --reason "suite"
  ROW=$(db "SELECT COUNT(*) FROM ipbanlist WHERE list='198.51.100.7' AND rtime > NOW()")
  [ "$ROW" = "1" ] && ok "the ban is active in ipbanlist" \
                   || no "the ban is active in ipbanlist" "rows: ${ROW:-0}"
  WHY=$(db "SELECT reason FROM ipbanlist WHERE list='198.51.100.7'")
  [ "$WHY" = "suite" ] && ok "--reason is stored" || no "--reason is stored" "got '$WHY'"

  # The login-server matches whole octets only, so CIDR has to be translated
  tm "ban translates /24 to the octet form" "203.0.113.\*"  $RA ban 203.0.113.0/24 --days 7
  CIDR=$(db "SELECT COUNT(*) FROM ipbanlist WHERE list='203.0.113.*'")
  [ "$CIDR" = "1" ] && ok "the /24 is stored as 203.0.113.*" \
                    || no "the /24 is stored as 203.0.113.*"
  DAYS=$(db "SELECT DATEDIFF(rtime, NOW()) FROM ipbanlist WHERE list='203.0.113.*'")
  [ "$DAYS" = "6" ] || [ "$DAYS" = "7" ] && ok "--days sets the expiry" \
                                         || no "--days sets the expiry" "datediff $DAYS"

  tm "bans lists the active ones"  "198.51.100.7"  $RA bans

  # A prefix the login-server cannot express must be refused, not widened
  tf "ban refuses a /25"                      $RA ban 203.0.113.0/25
  tf "ban refuses a non-address"              $RA ban notanip
  tf "ban refuses SQL punctuation"            $RA ban "1.2.3.4; DROP TABLE login"
  [ "$(db "SELECT COUNT(*) FROM login")" -gt 0 ] && ok "the login table survived that" \
                                                 || no "the login table survived that"

  tm "unban removes the ban"       "unbanned 198.51.100.7"  $RA unban 198.51.100.7
  GONE=$(db "SELECT COUNT(*) FROM ipbanlist WHERE list='198.51.100.7'")
  [ "$GONE" = "0" ] && ok "the row is gone after unban" || no "the row is gone after unban"
  tf "unban reports an address that was not banned"  $RA unban 198.51.100.250

  # The ban has to actually stop a login, not merely sit in a table.
  db "DELETE FROM login WHERE userid='ratestban'" >/dev/null 2>&1
  db "INSERT INTO login (userid,user_pass,sex,email) VALUES ('ratestban','banpass123','M','a@b.c')" >/dev/null 2>&1
  unban; sleep 4
  if login_retry ratestban banpass123; then
    ok "the account logs in before the ban"
    $RA ban 127.0.0.1 --reason "suite enforcement" >/dev/null 2>&1
    sleep 2
    login_as ratestban banpass123 >/dev/null 2>&1
    [ "$?" != "0" ] && ok "a banned address is refused" || no "a banned address is refused"
    $RA unban 127.0.0.1 >/dev/null 2>&1
    unban; sleep 4
    t "unbanning restores access"  login_retry ratestban banpass123
  else
    no "the account logs in before the ban"
  fi

  # purge drops expired rows and keeps live ones
  db "INSERT INTO ipbanlist (list,btime,rtime,reason) VALUES ('198.51.100.9', NOW(), DATE_SUB(NOW(), INTERVAL 1 DAY), 'expired')" >/dev/null 2>&1
  $RA bans --purge >/dev/null 2>&1
  EXP=$(db "SELECT COUNT(*) FROM ipbanlist WHERE list='198.51.100.9'")
  [ "$EXP" = "0" ] && ok "bans --purge drops expired rows" || no "bans --purge drops expired rows"
  LIVE=$(db "SELECT COUNT(*) FROM ipbanlist WHERE list='203.0.113.*'")
  [ "$LIVE" = "1" ] && ok "bans --purge keeps active rows" || no "bans --purge keeps active rows"

  db "DELETE FROM ipbanlist WHERE list LIKE '198.51.100%' OR list LIKE '203.0.113%'" >/dev/null 2>&1
  db "DELETE FROM login WHERE userid='ratestban'" >/dev/null 2>&1
else
  skip "ip ban tests (no database)"
fi

# --- 8. backups -------------------------------------------------------------
group "backup"
BDIR=$(mktemp -d)
if RATHENA_BACKUP_DIR="$BDIR" $RA backup >/dev/null 2>&1; then
  ok "backup runs"
  LATEST=$(ls -1t "$BDIR"/ragnarok-*.sql.gz "$BDIR"/ragnarok-*.sql.gz.age 2>/dev/null | head -1)
  [ -s "$LATEST" ] && ok "backup writes a non-empty database file" || no "backup writes a non-empty database file"
  case "$LATEST" in
    *.sql.gz.age) SETTINGS=${LATEST%.sql.gz.age}.config.tar.gz.age ;;
    *)            SETTINGS=${LATEST%.sql.gz}.config.tar.gz ;;
  esac
  [ -s "$SETTINGS" ] && ok "backup writes matching import settings" \
                     || no "backup writes matching import settings" "missing $SETTINGS"
  case "$LATEST" in
    *.age) ok "backup is age-encrypted"
           head -c 22 "$LATEST" | grep -q "age-encryption" \
             && ok "database backup carries the age header" || no "database backup carries the age header"
           head -c 22 "$SETTINGS" | grep -q "age-encryption" \
             && ok "settings backup carries the age header" || no "settings backup carries the age header"
           SETTINGS_LIST=$(age -d -i "$HOME/.config/secretspec/age-identity.txt" "$SETTINGS" | tar -tzf -) ;;
    *)     SETTINGS_LIST=$(tar -tzf "$SETTINGS")
           skip "backup is age-encrypted (no age key on this machine)" ;;
  esac
  th "settings backup contains conf/import"          '^conf/import/'          "$SETTINGS_LIST"
  th "settings backup contains nested message imports" '^conf/msg_conf/import/' "$SETTINGS_LIST"
  th "settings backup contains db/import"            '^db/import/'            "$SETTINGS_LIST"
  [ ! -f secrets.age ] || th "settings backup contains secrets.age" '^secrets.age$' "$SETTINGS_LIST"
  ls "$BDIR"/*.part >/dev/null 2>&1 && no "backup leaves no .part file" || ok "backup leaves no .part file"
  # Retention counts restore points, not the two files in each pair.
  for i in 1 2 3 4; do sleep 1; RATHENA_BACKUP_DIR="$BDIR" RATHENA_BACKUP_KEEP=2 $RA backup >/dev/null 2>&1; done
  SQL_N=$(find "$BDIR" -maxdepth 1 -type f -name 'ragnarok-*.sql.gz*' | wc -l)
  CFG_N=$(find "$BDIR" -maxdepth 1 -type f -name 'ragnarok-*.config.tar.gz*' | wc -l)
  [ "$SQL_N" = 2 ] && [ "$CFG_N" = 2 ] && ok "RATHENA_BACKUP_KEEP prunes complete restore points" \
                 || no "RATHENA_BACKUP_KEEP prunes complete restore points" "$SQL_N database + $CFG_N settings files"
else
  no "backup runs"
fi

# --- 9. restore -------------------------------------------------------------
group "restore"
tf "restore refuses without confirmation"  env RATHENA_RESTORE_CONFIRM= bash rathena restore
# The running-server guard fires before the confirmation prompt, and under
# `devenv test` the servers are always up, so the hint is only reachable when
# they are not.
if [ "$(pgrep -cf '^\./(login|char|map)-server$' || true)" = "0" ]; then
  tm "restore says how to confirm"  "--yes"  env RATHENA_RESTORE_CONFIRM= bash rathena restore
else
  skip "restore says how to confirm (servers running; the stop guard fires first)"
fi

tm "restore refuses while the servers are running" "still running" \
   env RATHENA_RESTORE_CONFIRM=yes bash rathena restore

if [ "${RATHENA_TEST_DESTRUCTIVE:-0}" = "1" ]; then
  SRC=$(ls -1t "$BDIR"/ragnarok-*.sql.gz "$BDIR"/ragnarok-*.sql.gz.age 2>/dev/null | head -1)
  BEFORE_N=$(db "SELECT COUNT(*) FROM login")
  if [ -n "$SRC" ] && $RA restore "$SRC" --yes >/dev/null 2>&1; then
    ok "restore completes"
    AFTER_N=$(db "SELECT COUNT(*) FROM login")
    [ "$BEFORE_N" = "$AFTER_N" ] && ok "restore preserves the account count" \
                                 || no "restore preserves the account count" "$BEFORE_N -> $AFTER_N"
    [ "$(db "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ragnarok'")" -ge 60 ] \
      && ok "restore brings back the full schema" || no "restore brings back the full schema"
    ls -1t backups/pre-restore-* >/dev/null 2>&1 && ok "restore leaves a safety dump" \
                                                 || no "restore leaves a safety dump"
  else
    no "restore completes" "source: ${SRC:-none}"
  fi
else
  skip "restore round trip (needs the servers stopped; RATHENA_TEST_DESTRUCTIVE=1 to force)"
fi
rm -rf "$BDIR"

# --- 9b. the devenv tasks ---------------------------------------------------
# ./rathena covers the commands that take arguments, but `devenv tasks run` is
# still the documented interface for the rest and is what `devenv up` depends
# on. Exercise the tasks directly, not through the wrapper.
group "devenv tasks"

# Every task the header promises must exist. devenv exits non-zero on an
# unknown task name, so this catches a task renamed in one place only.
for task in build rebuild check configure secrets peppers identity passwd \
            dev-accounts backup restore db-init ping; do
  if grep -q "\"rathena:$task\"" "$DEVENV_ROOT/devenv.nix"; then
    ok "task rathena:$task is defined"
  else
    no "task rathena:$task is defined" "named in the docs but not in devenv.nix"
  fi
done

# Tasks that take no arguments and change nothing, run as tasks. This also
# covers calling devenv from inside the devenv environment, which is how an
# operator in `devenv shell` would do it.
TOUT=$(devenv tasks run rathena:check 2>&1)
th "rathena:check runs as a task"            "pre-flight check"  "$TOUT"
th "rathena:check reports on stderr, not swallowed as JSON stdout" \
   "failure\(s\)"  "$TOUT"

sleep 4   # stay under ddos_count connections per ddos_interval
TOUT=$(devenv tasks run rathena:ping 2>&1)
th "rathena:ping runs as a task"             "6900"  "$TOUT"

TOUT=$(devenv tasks run rathena:secrets 2>&1)
th "rathena:secrets runs as a task"          "interserver|database password|keeping"  "$TOUT"
NOW=$(sed -n "s/^passwd: //p" conf/import/secret_conf.txt | tail -1)
[ -n "$NOW" ] && ok "rathena:secrets left the credentials in place" \
              || no "rathena:secrets left the credentials in place"

TOUT=$(devenv tasks run rathena:backup 2>&1)
th "rathena:backup runs as a task"           "database backup"  "$TOUT"
th "rathena:backup reports its settings pair" "settings backup"  "$TOUT"

# rathena:db-init is what `devenv up` runs first; it must be safe to repeat.
TOUT=$(env -u MYSQL_PWD devenv tasks run rathena:db-init 2>&1)
if printf '%s' "$TOUT" | grep -q "schema already present"; then
  ok "rathena:db-init is idempotent"
else
  no "rathena:db-init is idempotent" "$(printf '%s' "$TOUT" | tail -2 | tr '\n' ' ')"
fi

# --- 10. secrets stay out of git -------------------------------------------
group "secrets are not in git"
STATE_REL=${STATE#"$PWD"/}
for f in conf/import/secret_conf.txt conf/import/pepper_conf.txt \
         conf/import/deploy_conf.txt "$STATE_REL/db_secret_conf.txt" \
         "$STATE_REL/inter_runtime_conf.txt" .env; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    no "$f is gitignored" "it is tracked"
  else
    ok "$f is gitignored"
  fi
done
LIVE=$(sed -n 's/^passwd: //p' conf/import/secret_conf.txt | tail -1)
if [ -n "$LIVE" ] && git grep -qF "$LIVE" -- . 2>/dev/null; then
  no "the live interserver password is in no tracked file" "found in git grep"
else
  ok "the live interserver password is in no tracked file"
fi
if git ls-files --error-unmatch secrets.age >/dev/null 2>&1; then
  no "secrets.age is not tracked" "deployment secrets belong in backups, not git"
elif git check-ignore -q secrets.age; then
  ok "secrets.age is gitignored"
else
  no "secrets.age is gitignored"
fi

# --- summary ----------------------------------------------------------------
printf "\n%d passed, %d failed, %d skipped\n\n" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
