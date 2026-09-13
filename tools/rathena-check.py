#!/usr/bin/env python3
"""Pre-flight audit before exposing an rAthena server to the internet.

Reports only what is actually wrong, with the fix for each finding.
Exit code is 1 if any FAIL was reported, so it can gate a deploy.
"""
import os
import re
import socket
import subprocess
import sys

ROOT = os.environ.get("DEVENV_ROOT", "/workspaces/rathena")
STATE = os.environ.get("RATHENA_STATE_DIR", os.environ.get("DEVENV_STATE", os.path.join(ROOT, ".devenv/state")))
PORTS = [("login-server", 6900), ("char-server", 6121), ("map-server", 5121)]

fails = 0
warns = 0


def say(*a):
    """devenv captures task stdout as JSON, so report on stderr."""
    print(*a, file=sys.stderr)


def ok(msg):
    say(f"  \033[32mOK  \033[0m {msg}")


def warn(msg, fix=None):
    global warns
    warns += 1
    say(f"  \033[33mWARN\033[0m {msg}")
    if fix:
        say(f"         fix: {fix}")


def fail(msg, fix=None):
    global fails
    fails += 1
    say(f"  \033[31mFAIL\033[0m {msg}")
    if fix:
        say(f"         fix: {fix}")


def conf_value(relpath, key):
    """Last occurrence wins, matching rAthena's import semantics."""
    path = os.path.join(ROOT, relpath)
    if not os.path.exists(path):
        return None
    found = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("//") or ":" not in line:
                continue
            k, _, v = line.partition(":")
            if k.strip() == key:
                found = v.strip()
    return found


def db_conf():
    conf = {}
    for path in (
        os.path.join(ROOT, "conf/import/inter_conf.txt"),
        os.path.join(STATE, "db_secret_conf.txt"),
        os.path.join(STATE, "inter_runtime_conf.txt"),
    ):
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if ":" in line and not line.startswith("//"):
                    k, _, v = line.partition(":")
                    conf[k.strip()] = v.strip()
    return conf


def mysql(sql):
    c = db_conf()
    if not c:
        return None
    mariadb = os.environ.get("RATHENA_MYSQL_BIN", "mariadb")
    cmd = [mariadb, "-h", c.get("login_server_ip", "127.0.0.1"),
           "-P", c.get("login_server_port", "3306"),
           "-u", c.get("login_server_id", "ragnarok"),
           c.get("login_server_db", "ragnarok"), "-sN", "-e", sql]
    env = os.environ.copy()
    env["MYSQL_PWD"] = c.get("login_server_pw", "ragnarok")
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return res.stdout.strip() if res.returncode == 0 else None


say("\nrAthena pre-flight check\n")

# ---------------------------------------------------------------- connection
say("Connection (wiki: /wiki/connecting)")
char_ip = conf_value("conf/import/deploy_conf.txt", "char_ip") or conf_value("conf/import/char_conf.txt", "char_ip")
map_ip = conf_value("conf/import/deploy_conf.txt", "map_ip") or conf_value("conf/import/map_conf.txt", "map_ip")

for label, value in (("char_ip", char_ip), ("map_ip", map_ip)):
    if value is None:
        warn(f"{label} is not set - rAthena will auto-detect, which is unreliable behind NAT",
             "./rathena configure")
    elif value.startswith("127.") or value == "localhost":
        fail(f"{label} is {value} - remote clients cannot connect",
             "set RATHENA_PUBLIC_IP in .env, then: ./rathena configure")
    else:
        ok(f"{label} = {value}")

name = conf_value("conf/import/deploy_conf.txt", "server_name") or conf_value("conf/import/char_conf.txt", "server_name")
if not name or name == "rAthena":
    warn("server_name is still the default", "set RATHENA_SERVER_NAME in .env, then: ./rathena configure")
else:
    ok(f"server_name = {name}")

# ------------------------------------------------------------------ security
say("\nSecurity")
inter_user = mysql("SELECT userid FROM login WHERE account_id=1;")
if inter_user is None:
    warn("cannot read the login table (is the database running?)")
elif inter_user == "s1":
    fail("interserver account is still the default s1/p1",
         "./rathena configure")
else:
    ok(f"interserver account renamed ({inter_user})")

# PASSWD_FLAG_ENROLL (0x20): the account has no working password until its
# owner sets one, so anyone who knows the name can claim it meanwhile.
enrolling = mysql("SELECT COALESCE(GROUP_CONCAT(userid),'') FROM login WHERE passwd_type & 32;")
if enrolling:
    warn(f"waiting for a new password: {enrolling}",
         "anyone who knows the name can claim it; cancel with "
         "./rathena passwd <account> --cancel-enroll")

plain = mysql("SELECT COUNT(*) FROM login WHERE passwd_type=0 AND user_pass NOT LIKE '$argon2id$%';")
if plain and plain != "0":
    warn(f"{plain} account(s) are not hashed yet",
         "./login-server --encrypt-passwords")
elif plain == "0":
    ok("all passwords are hashed")

wire_pepper = conf_value("conf/import/pepper_conf.txt", "password_pepper")
if wire_pepper:
    # Base types 1 and 2 were made from a cleartext password and cannot be
    # checked against MD5(fixed-key + password). Type 3 is the wire-compatible
    # form. Legacy plaintext rows can still verify the encrypted handshake,
    # though the ordinary unhashed-password warning above covers them.
    incompatible = mysql(
        "SELECT COALESCE(GROUP_CONCAT(userid),'') FROM login "
        "WHERE sex <> 'S' AND (passwd_type & 15) IN (1,2);"
    )
    if incompatible is None:
        warn("cannot audit accounts for <passwordencrypt> compatibility")
    elif incompatible:
        fail(f"accounts cannot use required <passwordencrypt>: {incompatible}",
             "reset each with './rathena passwd <account>' or use '--enroll'")
    else:
        ok("all hashed accounts support required <passwordencrypt>")

dev = mysql("SELECT COALESCE(GROUP_CONCAT(userid),'') FROM login WHERE userid IN ('player','gmadmin');")
if dev:
    fail(f"development accounts still exist: {dev}",
         "DELETE FROM login WHERE userid IN ('player','gmadmin'); -- they use their own name as the password")
elif dev == "":
    ok("no development accounts")

groups = os.path.join(ROOT, "conf/import/groups.yml")
if os.path.exists(groups):
    body = open(groups, encoding="utf-8", errors="replace").read()
    if re.search(r"Id:\s*0\b.*?all_commands:\s*true", body, re.S):
        fail("group 0 (every player) has all_commands: true - anyone can @item, @warp, @zeny",
             "remove all_commands from Id: 0 in conf/import/groups.yml")
    else:
        ok("group 0 has no all_commands")

if conf_value("conf/import/login_conf.txt", "new_account") == "yes":
    warn("new_account: yes - anyone can self-register with _M / _F",
         "set new_account: no in conf/import/login_conf.txt if you want a closed server")
else:
    ok("self-registration disabled")

# the live interserver password must never appear in a tracked file
secret_conf = os.path.join(ROOT, "conf/import/secret_conf.txt")
live_pass = None
if os.path.exists(secret_conf):
    with open(secret_conf, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("passwd:"):
                live_pass = line.partition(":")[2].strip()

if live_pass:
    hit = subprocess.run(["git", "grep", "-l", "-F", live_pass],
                         capture_output=True, text=True, cwd=ROOT).stdout.strip()
    if hit:
        fail(f"the interserver password appears in tracked file(s): {hit.replace(chr(10), ', ')}",
             "rotate it: devenv tasks run rathena:configure")
    else:
        ok("interserver password is not in any tracked file")
else:
    warn("conf/import/secret_conf.txt not found - credentials may be inline",
         "./rathena configure")

for path, label in (
    (os.path.join(ROOT, "conf/import/secret_conf.txt"), "conf/import/secret_conf.txt"),
    (os.path.join(STATE, "db_secret_conf.txt"), "$DEVENV_STATE/db_secret_conf.txt"),
):
    if not os.path.exists(path):
        warn(f"{label} missing", "./rathena secrets")
    elif oct(os.stat(path).st_mode & 0o777) != oct(0o600):
        warn(f"{label} is mode {oct(os.stat(path).st_mode & 0o777)[2:]}, expected 600",
             f"chmod 600 {path}")
    else:
        ok(f"{label} present, mode 600")

c = db_conf()
if c.get("login_server_pw") == "ragnarok":
    warn("the database password is the default 'ragnarok'",
         "only reachable on loopback today, but change it before exposing MariaDB")

# --------------------------------------------------------------------- rates
say("\nGameplay")
base_exp = conf_value("conf/import/battle_conf.txt", "base_exp_rate")
if base_exp and int(base_exp) >= 1000:
    warn(f"base_exp_rate is {base_exp} ({int(base_exp)//100}x) - development setting",
         "adjust conf/import/battle_conf.txt")
elif base_exp:
    ok(f"base_exp_rate = {base_exp}")

# --------------------------------------------------------------------- ports
say("\nPorts (local)")
for label, port in PORTS:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            ok(f"{label} listening on {port}")
    except OSError:
        fail(f"{label} not listening on {port}", "devenv up")

say(f"\n{fails} failure(s), {warns} warning(s)\n")
if fails:
    print("Resolve the failures before exposing the server.\n")
sys.exit(1 if fails else 0)
