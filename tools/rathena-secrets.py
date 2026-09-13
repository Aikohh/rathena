#!/usr/bin/env python3
"""Generate the rAthena secrets this checkout needs.

No external secret manager, and deliberately NOT in secrets.age: these values
are disposable. The server owns both ends of each one, so deleting them is
harmless - the next start regenerates them, ALTERs the MariaDB user and
rewrites the login row to match. Nothing is lost.

The peppers are the opposite: regenerating one invalidates every stored
password, so it must survive a lost machine. That is what secrets.age and the
age key are for. Keeping the two apart means a server without peppers needs no
age key at all, and these rotatable values never enter git history.

The values live in gitignored files, and each file has exactly one owner.
Runtime infrastructure belongs under DEVENV_STATE; conf/import remains for
operator-authored server configuration.

    conf/import/secret_conf.txt          interserver userid/passwd  (this script)
    $DEVENV_STATE/db_secret_conf.txt     database password          (this script)
    $DEVENV_STATE/inter_runtime_conf.txt allocated port             (devenv)
    conf/import/deploy_conf.txt          char_ip/map_ip/server_name (configure)

Run it on a fresh clone, before 'devenv up':

    ./rathena secrets

Existing values are preserved. To replace one:

    ./rathena secrets --rotate inter_pass
    ./rathena secrets --rotate all

Environment overrides win over generation, so a value can still be pinned:
RATHENA_INTER_USER, RATHENA_INTER_PASS, RATHENA_DB_PASS.
"""
import argparse
import os
import secrets
import string
import sys


def out(msg=""):
    """devenv captures task stdout as JSON, so report on stderr."""
    print(msg, file=sys.stderr)

ROOT = os.environ.get("DEVENV_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.environ.get("RATHENA_STATE_DIR", os.environ.get("DEVENV_STATE", os.path.join(ROOT, ".devenv/state")))

SECRET_CONF = "conf/import/secret_conf.txt"
DB_SECRET_CONF = os.path.join(STATE, "db_secret_conf.txt")

# The interserver credentials travel in fixed 24-byte packet fields
# (src/char/char.hpp userid[24]/passwd[24], read with NAME_LENGTH in
# loginclif.cpp:403). Anything longer is silently truncated on the wire and the
# char-server is refused with "Invalid password".
INTER_MAX = 23

DB_SCOPES = ["login_server", "ipban_db", "char_server", "map_server", "web_server", "log_db"]

ALPHABET = string.ascii_letters + string.digits


def gen(n, prefix=""):
    return prefix + "".join(secrets.choice(ALPHABET) for _ in range(n - len(prefix)))


def read_kv(relpath, key):
    path = os.path.join(ROOT, relpath)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("//") or ":" not in line:
                continue
            k, _, v = line.partition(":")
            if k.strip() == key:
                return v.strip()
    return None


def write_conf(relpath, header, lines):
    path = os.path.join(ROOT, relpath)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(f"// {h}\n" for h in header))
        fh.write("".join(f"{k}: {v}\n" for k, v in lines))
    os.chmod(path, 0o600)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rotate", nargs="*", metavar="NAME",
                    choices=["inter_user", "inter_pass", "db_pass"],
                    help="regenerate these (no names = all of them)")
    args = ap.parse_args()

    rotate = set()
    if args.rotate is not None:
        rotate = set(args.rotate) if args.rotate else {"inter_user", "inter_pass", "db_pass"}

    report = []

    # --- interserver credentials -------------------------------------------
    user = read_kv(SECRET_CONF, "userid")
    passwd = read_kv(SECRET_CONF, "passwd")

    new_user = os.environ.get("RATHENA_INTER_USER") or (
        gen(12, "s") if (not user or "inter_user" in rotate) else user)
    new_pass = os.environ.get("RATHENA_INTER_PASS") or (
        gen(INTER_MAX) if (not passwd or "inter_pass" in rotate) else passwd)

    for label, value in (("RATHENA_INTER_USER", new_user), ("RATHENA_INTER_PASS", new_pass)):
        if len(value) > INTER_MAX:
            print(f"error: {label} is {len(value)} characters; the packet field holds {INTER_MAX}",
                  file=sys.stderr)
            sys.exit(1)

    inter_changed = (new_user != user) or (new_pass != passwd)
    write_conf(
        SECRET_CONF,
        ["Interserver credentials. GITIGNORED - never commit this file.",
         "Written by tools/rathena-secrets.py."],
        [("userid", new_user), ("passwd", new_pass)],
    )
    report.append(("interserver credentials", "generated" if inter_changed else "kept"))

    # --- database password --------------------------------------------------
    db_pass = read_kv(DB_SECRET_CONF, "login_server_pw")
    new_db = os.environ.get("RATHENA_DB_PASS") or (
        gen(24) if (not db_pass or "db_pass" in rotate) else db_pass)

    db_changed = new_db != db_pass
    write_conf(
        DB_SECRET_CONF,
        ["Database password. GITIGNORED - never commit this file.",
         "Written by tools/rathena-secrets.py; applied by devenv on the next start."],
        [(f"{scope}_pw", new_db) for scope in DB_SCOPES],
    )
    report.append(("database password", "generated" if db_changed else "kept"))

    for what, state in report:
        out(f"  {state:<10} {what}")

    if inter_changed or db_changed:
        out("\nStored in gitignored runtime files (mode 600).")
        if inter_changed:
            out("Interserver credentials changed - the login table is updated on the")
            out("next 'devenv up'.")
        if db_changed:
            out("Database password changed - applied on the next 'devenv up'.")
    else:
        out("\nNothing to do. Use --rotate to replace a value.")


if __name__ == "__main__":
    main()
