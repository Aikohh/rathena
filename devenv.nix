# rAthena development and deployment environment.
#
# ---------------------------------------------------------------------------
# NEW SERVER, FROM NOTHING
# ---------------------------------------------------------------------------
#   git clone https://github.com/Aikohh/rathena.git -b server
#   cd rathena
#   cp .env.example .env                optional; edit to change any setting
#   ./rathena build                     compile login/char/map/web
#   devenv up                           start MariaDB and the three servers
#
# That is all. The interserver credentials and database password are generated
# on the first 'devenv up' and kept afterwards.
#
# Optionally, before the first start, turn on the password hash pepper so a
# leaked database is unattackable even for weak passwords:
#
#   age-keygen -o ~/.config/secretspec/age-identity.txt
#   ./rathena peppers                   generate and store them in secrets.age
#   ./rathena backup                    archive it with the database/settings
#
# Then BACK UP ~/.config/secretspec/age-identity.txt separately. It is the only
# thing that can decrypt secrets.age and the encrypted backup pair.
#
# ---------------------------------------------------------------------------
# EXISTING SERVER, NEW MACHINE
# ---------------------------------------------------------------------------
#   git clone https://github.com/Aikohh/rathena.git -b server
#   cd rathena
#   ./rathena identity /path/to/age-identity.txt                    # see below
#   cp .env.example .env                optional; edit to change any setting
#   ./rathena build
#   devenv up
#
# Install the identity before restoring an encrypted backup. The matching
# settings archive restores secrets.age, .env and every import directory along
# with the database. Starting a restored peppered database without those files
# would reject every account with a bare "Invalid password".
#
# When secrets.age is already present, rathena:identity verifies the key before
# installing it. Before a restore there may be no secrets.age yet, so final
# verification happens when ./rathena restore decrypts the backup.
# It reports the file it read the key from, so a temporary copy can be
# removed afterwards. It never deletes it - that file may be the only backup.
# Piping avoids leaving a copy at all, e.g.
#
#   pass show rathena/age | ./rathena identity
#
# The database and import settings are NOT in git. Restore them together from
# a backup pair:
#
#   ./rathena restore backups/<file>.sql.gz.age --yes
#
# Without that, the server starts empty: no accounts, no characters, and only
# the upstream import templates plus devenv's required connection files.
#
# ---------------------------------------------------------------------------
# SETTINGS  (.env)
# ---------------------------------------------------------------------------
# Every setting below is read from .env, which devenv loads automatically.
# The file is OPTIONAL and gitignored: without it each value falls back to the
# default baked into this file, which is what a fresh clone runs on.
#
#   cp .env.example .env     then edit; .env.example documents each setting
#
# Secrets do NOT go there: the peppers live in secrets.age, the interserver
# credentials in conf/import/, and the database password in DEVENV_STATE.
#
#   RATHENA_PACKETVER         client packet version (compile time)
#   RATHENA_PUBLIC_IP         WAN address; "auto" detects it
#   RATHENA_SERVER_NAME       server and wisp name
#   RATHENA_BACKUP_INTERVAL   seconds between automatic backups; 0 disables
#   RATHENA_BACKUP_KEEP       how many dumps to retain
#   RATHENA_BACKUP_DIR        where to write them
#   RATHENA_BACKUP_RECIPIENT  age public key to encrypt backups to
#   RATHENA_WIRE_PEPPER_ENABLE  1 to require <passwordencrypt> clients
#
# Set them in .env - copy .env.example and edit. The file is optional and
# gitignored; without it every setting falls back to the default baked into
# this file, which is what a fresh clone gets.
#
# Prefer ./rathena for anything taking an argument; see the section above.
#
# ---------------------------------------------------------------------------
# GOING PUBLIC
# ---------------------------------------------------------------------------
# Set the address and name in .env (see SETTINGS above):
#
#   RATHENA_PUBLIC_IP=1.2.3.4
#   RATHENA_SERVER_NAME=MyServer
#
# then apply them:
#
#   ./rathena configure                 writes the deployment config; works
#                                       while the database is stopped
#   devenv up                           RESTART REQUIRED - see below
#   ./rathena check                     audit before exposing the server
#
# Flags override .env for a one-off:
#
#   ./rathena configure --ip 1.2.3.4 --name MyServer
#
# ./rathena configure only writes config files. It works whether the stack is
# running or stopped; generated credentials and the login-table row are owned
# and synchronized by rathena:db-init during `devenv up`.
#
# But rAthena reads its configuration once, at startup, so nothing takes
# effect until the restart. Until then the servers keep advertising the old
# char_ip/map_ip and clients still cannot connect.
#
# rathena:check must report zero failures. Open TCP 6900, 6121 and 5121;
# never expose 3306. See https://github.com/rathena/rathena/wiki/connecting
#
# ---------------------------------------------------------------------------
# ./rathena  -  the command-line wrapper
# ---------------------------------------------------------------------------
# devenv tasks take no positional arguments: every extra token is parsed as
# another task name. ./rathena takes real ones and re-executes inside
# `devenv shell` when needed, so it works from a plain terminal.
#
#   ./rathena help                     the same list, with the options
#
# Setting up
#   ./rathena build                    compile login/char/map/web
#   ./rathena rebuild                  clean rebuild, after a PACKETVER change
#   ./rathena configure                apply RATHENA_PUBLIC_IP and _SERVER_NAME
#   ./rathena check                    pre-flight audit; non-zero on failures
#
# Running it
#   ./rathena ping [HOST]              reachability, and which char-server
#                                      address a client is actually handed
#   ./rathena sql ["QUERY"]            SQL prompt, or one statement
#   ./rathena backup                   take one backup now
#   ./rathena restore [FILE] --yes     restore one; servers must be stopped
#
# Accounts
#   ./rathena gm <account> [--level N] set the group; 99 Admin, 0 Player
#   ./rathena passwd <account>         set a password (prompts, no echo)
#   ./rathena passwd <acct> --enroll   let the owner set it at their next login
#   ./rathena dev-accounts             create player/player and gmadmin/gmadmin
#                                      for local testing; rathena:check fails
#                                      while either still exists
#   ./rathena ban <ip|cidr> [--days N] block logins from an address
#   ./rathena unban <ip|cidr>          lift it
#   ./rathena bans [--purge]           list active bans, drop expired rows
#
# Secrets
#   ./rathena secrets [--rotate NAME]  the generated interserver and DB secrets
#   ./rathena peppers                  generate the operator peppers
#   ./rathena identity [FILE]          install the age key on a new machine
#
# The tasks below still exist and are what `devenv up` uses; the wrapper is
# the interface for anything that needs an argument.
#
# ---------------------------------------------------------------------------
# TASKS
# ---------------------------------------------------------------------------
#   rathena:build         compile (incremental)
#   rathena:rebuild       force a clean rebuild, e.g. after a PACKETVER change
#   rathena:configure     set the WAN IP and server name (database not needed)
#   rathena:check         pre-flight audit; non-zero exit on failures
#   rathena:secrets       generate the secrets (see ./rathena secrets to rotate)
#   rathena:dev-accounts  create player/player and gmadmin/gmadmin
#   rathena:backup        live-safe mysqldump into backups/
#   rathena:restore       restore from a backup (see ./rathena restore)
#   rathena:db-init       re-run the database bootstrap by hand
#   rathena:ping          check the three ports without a game client
#
# ---------------------------------------------------------------------------
# GENERATED FILES (all gitignored)
# ---------------------------------------------------------------------------
#   conf/import/ and db/import/        upstream templates plus handwritten
#                                      operator configuration; back these up
#   conf/import/secret_conf.txt        interserver credentials  rathena-secrets
#   conf/import/deploy_conf.txt        WAN IP and server name   configure
#   conf/import/pepper_conf.txt        operator peppers         secretspec
#   $DEVENV_STATE/db_secret_conf.txt   database password        rathena-secrets
#   $DEVENV_STATE/inter_runtime_conf.txt  allocated DB port      devenv
#
# conf/devenv/ holds only the infrastructure templates that devenv regenerates.
# Edit gameplay settings directly under conf/import/; backups include them.
#
# ---------------------------------------------------------------------------
# OPERATOR SECRETS (optional, held in secretspec)
# ---------------------------------------------------------------------------
#   secretspec set RATHENA_HASH_PEPPER   server-side pepper mixed into every
#                                        password hash. Makes a leaked database
#                                        unattackable even for weak passwords.
#                                        NEVER rotate; losing it means every
#                                        account must be reset.
#   secretspec set RATHENA_WIRE_PEPPER   fixed <passwordencrypt> key. Not a
#                                        secret - the server hands it to any
#                                        caller - but deployment-specific.
#                                        Only applied when you also set
#                                        RATHENA_WIRE_PEPPER_ENABLE=1, because
#                                        it rejects every client that does not
#                                        use <passwordencrypt>.
#
# Stored in gitignored secrets.age, encrypted to the age identity. Every
# settings backup includes it; neither the encrypted file nor the key is in git.
#
# NEVER rotate RATHENA_HASH_PEPPER. It is mixed into every stored password, so
# replacing it means every account has to be reset one at a time with
# ./login-server --set-password <account>.
#
# The */import directories are gitignored and hold operator configuration.
# They are archived with every database backup. Secrets never go in git
# unencrypted.
#
# ---------------------------------------------------------------------------
# DAY TO DAY
# ---------------------------------------------------------------------------
#   logs        .devenv/run/processes/logs/*.log
#   database    .devenv/state/mysql/          (back this up, it is your data)
#
# Backups are encrypted to an age recipient when one is available, so a dump
# left on a NAS or in cloud storage discloses nothing - not the account
# emails, IPs or birthdates, and not the chat logs. Restore with:
#
#   age -d -i ~/.config/secretspec/age-identity.txt backups/<file>.sql.gz.age \
#     | gunzip -c | mariadb -h 127.0.0.1 -P <port> -u ragnarok ragnarok
#
# Encryption uses the RECIPIENT (public key), so unattended backups need no
# private-key prompt. Each restore point is a database dump plus a settings
# archive containing all three import directories, .env and secrets.age. Both
# are useless without the separately stored age identity. Test a restore before
# relying on them.
#
{ pkgs, lib, config, inputs, ... }:

let
  # rAthena's ./configure expects DIR/include + DIR/lib, nix splits dev/out
  zlibRoot = pkgs.symlinkJoin { name = "zlib-root"; paths = [ pkgs.zlib.dev pkgs.zlib.out ]; };
  pcreRoot = pkgs.symlinkJoin { name = "pcre-root"; paths = [ pkgs.pcre.dev pkgs.pcre.out ]; };

  mysqlBin = "${pkgs.mariadb.client}/bin/mariadb";
  mysqlDumpBin = "${pkgs.mariadb.client}/bin/mariadb-dump";

  # Every helper below needs the same two values, and rAthena resolves them
  # across the same import chain, where the last definition wins.
  #   conf/import/inter_conf.txt       generated: ips, usernames, DB names
  #   $DEVENV_STATE/db_secret_conf.txt generated: database password
  #   $DEVENV_STATE/inter_runtime_conf.txt generated: allocated DB port
  #
  # Sourced rather than duplicated; `ra_db` also exports MYSQL_PWD so the
  # password never appears in the process list, unlike `-p<password>`.
  dbLib = pkgs.writeShellScript "rathena-db-lib" ''
    STATE="''${RATHENA_STATE_DIR:-$DEVENV_STATE}"
    RA_CONF_FILES="conf/import/inter_conf.txt $STATE/db_secret_conf.txt $STATE/inter_runtime_conf.txt"

    # ra_conf <key> -> last value defined for that key, or empty
    ra_conf() {
      cat $RA_CONF_FILES 2>/dev/null | sed -n "s/^$1: //p" | tail -1
    }

    # ra_db -> sets RA_PORT and MYSQL_PWD, defines $RA. Non-zero if unconfigured.
    ra_db() {
      RA_PORT=$(ra_conf login_server_port)
      MYSQL_PWD=$(ra_conf login_server_pw)
      export MYSQL_PWD

      if [ -z "$RA_PORT" ]; then
        echo "$DEVENV_STATE/inter_runtime_conf.txt missing - run 'devenv up' first" >&2
        return 1
      fi

      RA="${mysqlBin} -h 127.0.0.1 -P $RA_PORT -u ragnarok ragnarok"
      return 0
    }

    # ra_db_ready -> non-zero until the ragnarok schema answers
    ra_db_ready() {
      $RA -e "SELECT 1 FROM login LIMIT 1" >/dev/null 2>&1
    }
  '';

  # --- automatic backups ----------------------------------------------------
  # Edit these for a permanent change; the matching RATHENA_BACKUP_* variable
  # still overrides each one for a single run.
  # Defaults, used when .env does not set the matching RATHENA_BACKUP_*.
  backupInterval = 3600;  # seconds between dumps; 0 disables them
  backupKeep     = 24;    # how many to retain; older ones are deleted
  backupDir      = "backups";

  # Client packet version. Override per-invocation with:
  #   RATHENA_PACKETVER=20130807 devenv tasks run rathena:build
  #   Korangar targets PACKETVER=20220406
  defaultPacketver = "20250716"; # WARPGATE 2025-07-16 client

  configureCmd = "./configure --with-zlib=${zlibRoot} --with-pcre=${pcreRoot} LIBS=\"-lresolv\"";

  # PACKETVER is compile-time, so a changed value forces a clean rebuild.
  buildScript = ''
    set -e
    cd "$DEVENV_ROOT"
    PV="''${RATHENA_PACKETVER:-${defaultPacketver}}"
    STAMP=.devenv/state/rathena-packetver
    echo "packetver: $PV"
    if [ ! -f Makefile ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$PV" ]; then
      echo "packetver changed or first build - cleaning"
      make clean >/dev/null 2>&1 || true
      ${configureCmd} --enable-packetver="$PV"
      mkdir -p "$(dirname "$STAMP")"
      echo "$PV" > "$STAMP"
    fi
    make server -j"$(nproc)"
  '';

  # Waits for MariaDB, creates the rathena user, points rAthena at the port
  # devenv actually allocated, and imports the schema once.
  initScript = pkgs.writeShellScript "rathena-db-init" ''
    set -e
    cd "''${DEVENV_ROOT:-/workspaces/rathena}"
    STATE="''${RATHENA_STATE_DIR:-$DEVENV_STATE}"
    export RATHENA_STATE_DIR="$STATE"
    mkdir -p "$STATE"

    # devenv captures task stdout as JSON, so `devenv tasks run rathena:db-init`
    # would print nothing but {}. Send every message below to stderr instead;
    # command substitution still captures its own stdout normally.
    exec 1>&2

    # The root connections below take their password from the environment if
    # one is set. A caller that exported MYSQL_PWD for the ragnarok user would
    # send it as root's, and every attempt would fail with "Access denied"
    # until the wait loop gave up two minutes later reporting the wrong cause.
    unset MYSQL_PWD

    # Upstream treats */import as generated output. Recreate the stock templates
    # and install this server's tracked overrides before any server can read
    # them. This also repairs a deliberately deleted import directory.
    ${pkgs.bash}/bin/bash tools/rathena-imports.sh

    for i in $(seq 1 120); do
      ${mysqlBin} -u root -e "SELECT 1" >/dev/null 2>&1 && break
      if [ "$i" = "120" ]; then
        echo "MariaDB not reachable as root (is 'devenv up' running?)" >&2
        exit 1
      fi
      sleep 1
    done

    PORT=$(${mysqlBin} -u root -sN -e "SELECT @@port")
    echo "MariaDB ready on 127.0.0.1:$PORT"

    # Generate anything missing before the credentials are used below. The
    # script is idempotent - existing values are kept - so this is safe on
    # every start and makes a fresh clone need no manual step.
    ${pkgs.python3}/bin/python3 tools/rathena-secrets.py

    # Written by tools/rathena-secrets.py. The fallback keeps a plain
    # 'devenv up' working on a clone where the script has not been run.
    DBPASS=$(sed -n 's/^login_server_pw: //p' "$STATE/db_secret_conf.txt" 2>/dev/null | tail -1)
    DBPASS="''${DBPASS:-''${RATHENA_DB_PASS:-ragnarok}}"

    # These are interpolated into SQL below. Generated values are alphanumeric,
    # but a hand-edited file or RATHENA_DB_PASS could carry a quote and break
    # the statement, so refuse anything outside [A-Za-z0-9._-].
    case "$DBPASS" in
      *[!A-Za-z0-9._-]*)
        echo "database password contains unsupported characters; use [A-Za-z0-9._-]" >&2
        exit 1
        ;;
    esac

    ${mysqlBin} -u root <<SQL
    CREATE DATABASE IF NOT EXISTS ragnarok;
    CREATE USER IF NOT EXISTS 'ragnarok'@'localhost' IDENTIFIED BY '$DBPASS';
    CREATE USER IF NOT EXISTS 'ragnarok'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
    ALTER USER 'ragnarok'@'localhost' IDENTIFIED BY '$DBPASS';
    ALTER USER 'ragnarok'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
    GRANT ALL PRIVILEGES ON ragnarok.* TO 'ragnarok'@'localhost';
    GRANT ALL PRIVILEGES ON ragnarok.* TO 'ragnarok'@'127.0.0.1';
    DROP USER IF EXISTS 'ragnarok'@'%';
    DELETE FROM mysql.global_priv WHERE LENGTH(User)=0;
    FLUSH PRIVILEGES;
    SQL

    # Only volatile database fields are written here. The generated
    # conf/import/inter_conf.txt imports them from DEVENV_STATE.
    {
      echo "// Generated by devenv (rathena-db-init) on every start."
      echo "// GITIGNORED - holds the port devenv allocated for MariaDB."
      echo "// Static settings live in conf/import/inter_conf.txt."
      for s in login_server ipban_db char_server map_server web_server log_db; do
        echo "$s"_port: "$PORT"
      done
    } > "$STATE/inter_runtime_conf.txt"

    # MYSQL_PWD instead of -p<password>: the latter is visible in `ps` output
    export MYSQL_PWD="$DBPASS"
    RA="${mysqlBin} -h 127.0.0.1 -P $PORT -u ragnarok ragnarok"
    if $RA -e "SELECT 1 FROM login LIMIT 1" >/dev/null 2>&1; then
      echo "schema already present, skipping import"

      # Migrations for databases created before argon2id. A login table that
      # exists is not necessarily a current one: without these the UPDATE below
      # fails with "Unknown column 'passwd_type'", the interserver credentials
      # are never applied, and the char-server is refused at every start.
      if ! $RA -e "SELECT \`passwd_type\` FROM login LIMIT 1" >/dev/null 2>&1; then
        $RA -e "ALTER TABLE \`login\` ADD COLUMN \`passwd_type\` tinyint unsigned NOT NULL DEFAULT 0;"
        echo "migrated: added login.passwd_type"
      fi

      # An argon2id hash is 98 characters. A narrower column silently truncates
      # it, which locks every account out on the next login.
      WIDTH=$($RA -sN -e "SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.columns WHERE table_schema='ragnarok' AND table_name='login' AND column_name='user_pass';")
      if [ -n "$WIDTH" ] && [ "$WIDTH" -lt 98 ]; then
        $RA -e "ALTER TABLE \`login\` MODIFY \`user_pass\` varchar(98) NOT NULL DEFAULT ''';"
        echo "migrated: widened login.user_pass to 98 for argon2id"
      fi
    else
      for f in sql-files/main.sql sql-files/logs.sql sql-files/web.sql; do
        echo "importing $f"
        $RA < "$f"
      done
      echo "schema imported into database 'ragnarok'"
    fi

    # Generated above; this only fires if that call somehow failed.
    if [ ! -f conf/import/secret_conf.txt ]; then
      echo "conf/import/secret_conf.txt missing - run: devenv tasks run rathena:secrets" >&2
      exit 1
    fi

    # Keep the login table in step with conf/import/secret_conf.txt. Rotating
    # the credentials is then just rathena-secrets.py plus a restart.
    IU=$(sed -n 's/^userid: //p' conf/import/secret_conf.txt | tail -1)
    IP_=$(sed -n 's/^passwd: //p' conf/import/secret_conf.txt | tail -1)

    # same reasoning as DBPASS: these end up inside an UPDATE statement
    case "$IU$IP_" in
      ""|*[!A-Za-z0-9._-]*)
        echo "interserver credentials are empty or contain unsupported characters" >&2
        echo "regenerate them with: python3 tools/rathena-secrets.py --rotate" >&2
        exit 1
        ;;
    esac
    # The stored password is hashed, so it cannot be compared directly.
    # Fingerprint the pair instead: rotating either half triggers the update.
    FP=$(printf '%s:%s' "$IU" "$IP_" | ${pkgs.coreutils}/bin/sha256sum | cut -c1-32)
    FPFILE=.devenv/state/rathena-interserver
    CURRENT=$($RA -sN -e "SELECT userid FROM login WHERE account_id=1;")

    if [ "$CURRENT" != "$IU" ] || [ "$(cat "$FPFILE" 2>/dev/null)" != "$FP" ]; then
      # passwd_type=0 so the login-server rehashes it to argon2id on first use
      $RA -e "UPDATE \`login\` SET \`userid\`='$IU', \`user_pass\`='$IP_', \`passwd_type\`=0 WHERE \`account_id\`=1;"
      mkdir -p "$(dirname "$FPFILE")"
      echo "$FP" > "$FPFILE"
      echo "interserver account updated in the login table ($IU)"
    fi

    # Bridge the operator-supplied secrets into config: rAthena cannot read the
    # environment. Rewritten every start, so clearing a secret disables the
    # feature instead of leaving a stale file behind.
    #
    # An environment variable still wins, which keeps the servers runnable
    # without secretspec or a decryption key.
    ra_secret() {
      if command -v secretspec >/dev/null 2>&1; then
        SECRETSPEC_PROVIDER="''${SECRETSPEC_PROVIDER:-age://secrets.age?identity=$HOME/.config/secretspec/age-identity.txt}" \
          secretspec get "$1" 2>/dev/null || true
      fi
    }

    HASH_PEPPER="''${RATHENA_HASH_PEPPER:-$(ra_secret RATHENA_HASH_PEPPER)}"
    WIRE_PEPPER="''${RATHENA_WIRE_PEPPER:-$(ra_secret RATHENA_WIRE_PEPPER)}"

    {
      echo "// Generated by devenv from secretspec on every start. GITIGNORED."
      echo "// Supply these with: secretspec set RATHENA_HASH_PEPPER"
      [ -n "$HASH_PEPPER" ] && echo "password_hash_pepper: $HASH_PEPPER"
      # Opt-in: a wire pepper makes the login-server reply with a constant
      # md5key, so ONLY a client configured with <passwordencrypt> can log in.
      # Every other client sends cleartext and is rejected with "is peppered
      # but the client sent a cleartext password". Enabling it by accident
      # locks out everyone, so it needs RATHENA_WIRE_PEPPER_ENABLE=1.
      if [ -n "$WIRE_PEPPER" ] && [ "''${RATHENA_WIRE_PEPPER_ENABLE:-0}" = "1" ]; then
        echo "password_pepper: $WIRE_PEPPER"
      fi
      true
    } > conf/import/pepper_conf.txt
    chmod 600 conf/import/pepper_conf.txt

    # A present-but-unreadable secrets.age means the age key is missing. Without
    # this check the server would start WITHOUT the pepper and every peppered
    # account would fail with a bare "Invalid password", which points nowhere
    # near the real cause.
    if [ -f secrets.age ] && [ -z "$HASH_PEPPER$WIRE_PEPPER" ]; then
      echo "" >&2
      echo "secrets.age exists but nothing in it can be decrypted." >&2
      echo "" >&2
      echo "If this is YOUR server and you have the age key:" >&2
      echo "    devenv tasks run rathena:identity < /path/to/age-identity.txt" >&2
      echo "" >&2
      echo "If you cloned someone else's repository, that file is theirs and" >&2
      echo "you cannot read it. Delete it and create your own:" >&2
      echo "    rm secrets.age" >&2
      echo "    age-keygen -o \$HOME/.config/secretspec/age-identity.txt" >&2
      echo "    devenv tasks run rathena:peppers" >&2
      echo "" >&2
      echo "Or skip peppers entirely - 'rm secrets.age' alone is enough." >&2
      echo "" >&2
      echo "Refusing to start: continuing without the pepper would reject" >&2
      echo "every existing account with a bare \"Invalid password\"." >&2
      exit 1
    fi

    if [ -n "$HASH_PEPPER" ]; then
      echo "hash pepper loaded from secretspec"
    fi

    # Deployment-specific addresses. Gitignored, because this checkout may be
    # moved between machines and the WAN IP changes with it.
    # Created only when missing, so a deliberate 'rathena:configure' run is
    # never overwritten on the next start.
    if [ ! -f conf/import/deploy_conf.txt ]; then
      IP="''${RATHENA_PUBLIC_IP:-127.0.0.1}"

      if [ "$IP" = "auto" ]; then
        IP=$(${pkgs.curl}/bin/curl -s --max-time 5 https://api.ipify.org || true)
        if [ -z "$IP" ]; then
          echo "could not detect the public IP, falling back to 127.0.0.1" >&2
          IP=127.0.0.1
        fi
      fi

      {
        echo "// Generated by devenv because it was missing. GITIGNORED."
        echo "// Addresses clients are told to connect to - they differ per machine."
        echo "// Set them properly with:"
        echo "//   RATHENA_PUBLIC_IP=<wan ip> devenv tasks run rathena:configure"
        echo "server_name: ''${RATHENA_SERVER_NAME:-rAthena}"
        echo "wisp_server_name: ''${RATHENA_SERVER_NAME:-rAthena}"
        echo "char_ip: $IP"
        echo "map_ip: $IP"
      } > conf/import/deploy_conf.txt
      echo "wrote conf/import/deploy_conf.txt (char_ip/map_ip = $IP)"
    fi

    echo "database ready (no dev accounts created)"
    echo "run 'devenv tasks run rathena:dev-accounts' if you want them"
  '';

  # Opt-in dev logins. Not created by 'devenv up' - run the task explicitly.
  # NOTE: the client rejects account names shorter than 6 characters.
  devAccountsScript = pkgs.writeShellScript "rathena-dev-accounts" ''
    set -e
    cd "''${DEVENV_ROOT:-/workspaces/rathena}"

    . ${dbLib}
    ra_db || exit 1

    if ! ra_db_ready; then
      echo "ragnarok database not reachable on 127.0.0.1:$RA_PORT" >&2
      exit 1
    fi

    $RA <<SQL
    INSERT INTO login (userid, user_pass, sex, email, group_id)
      SELECT 'player', 'player', 'M', 'player@local', 0 FROM DUAL
      WHERE NOT EXISTS (SELECT 1 FROM login WHERE userid = 'player');
    INSERT INTO login (userid, user_pass, sex, email, group_id)
      SELECT 'gmadmin', 'gmadmin', 'M', 'gmadmin@local', 99 FROM DUAL
      WHERE NOT EXISTS (SELECT 1 FROM login WHERE userid = 'gmadmin');
    SQL
    echo "dev accounts ready: player/player (group 0), gmadmin/gmadmin (group 99)"
  '';
  # One implementation, in tools/rathena-backup.sh, so the task, the periodic
  # loop and ./rathena all run the same code. The tools it needs are on PATH
  # inside the devenv environment.
  backupScript = pkgs.writeShellScript "rathena-backup" ''
    exec ${pkgs.bash}/bin/bash "''${DEVENV_ROOT:-/workspaces/rathena}/tools/rathena-backup.sh" "$@"
  '';

  # Periodic backups while 'devenv up' is running. Interval in seconds.
  # A dump is taken once at startup, then every RATHENA_BACKUP_INTERVAL.
  backupLoop = pkgs.writeShellScript "rathena-backup-loop" ''
    cd "''${DEVENV_ROOT:-/workspaces/rathena}"
    INTERVAL="''${RATHENA_BACKUP_INTERVAL:-${toString backupInterval}}"
    if [ "$INTERVAL" -le 0 ]; then
      echo "RATHENA_BACKUP_INTERVAL=$INTERVAL - periodic backups disabled"
      exec sleep infinity
    fi
    echo "periodic backups every ''${INTERVAL}s"
    while true; do
      ${backupScript} || echo "backup failed, will retry in ''${INTERVAL}s" >&2
      sleep "$INTERVAL"
    done
  '';

  waitDb = pkgs.writeShellScript "rathena-wait-db" ''
    cd "''${DEVENV_ROOT:-/workspaces/rathena}"
    . ${dbLib}
    for i in $(seq 1 180); do
      # re-read every pass: rathena-init writes the port while we are waiting
      if ra_db 2>/dev/null && ra_db_ready; then
        exit 0
      fi
      sleep 1
    done
    echo "timed out waiting for the ragnarok database" >&2
    exit 1
  '';

  waitTcp = pkgs.writeShellScript "rathena-wait-tcp" ''
    for i in $(seq 1 180); do
      (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && exit 0
      sleep 1
    done
    echo "timed out waiting for 127.0.0.1:$1" >&2
    exit 1
  '';
in
{
  dotenv.enable = true;

  devcontainer.enable = true;
  devcontainer.settings = {
    forwardPorts = [ 6900 6121 5121 3306 ];
    # published at container creation (docker/podman -p): rootless
    # pasta/slirp networking gives the container its own netns with no
    # inbound path from the host, so forwardPorts alone is not enough
    appPort = [ "6900:6900" "6121:6121" "5121:5121" ];
    portsAttributes = {
      "6900" = { label = "rAthena login"; };
      "6121" = { label = "rAthena char"; };
      "5121" = { label = "rAthena map"; };
      "3306" = { label = "MariaDB"; };
    };
  };

  # --- build toolchain + rAthena deps ---------------------------------------
  packages = with pkgs; [
    gnumake
    autoconf
    automake
    pkg-config
    cmake
    zlib
    zlib.dev
    pcre
    pcre.dev
    openssl
    openssl.dev
    age # secretspec 'age' provider: encrypts secrets.age
    libargon2 # argon2id password hashing
    libmysqlclient # provides mysql_config / client headers
    mariadb.client # mariadb CLI for schema import
    gdb
  ];

  languages.c.enable = true;
  languages.cplusplus.enable = true;

  # --- database -------------------------------------------------------------
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    initialDatabases = [{ name = "ragnarok"; }];
    settings.mysqld = {
      port = 3306; # devenv may allocate 3307+ if taken; init script follows it
      bind-address = "127.0.0.1";
    };
  };

  # --- tasks: `devenv tasks run <name>` -------------------------------------
  tasks = {
    "rathena:build".exec = buildScript; # compile login/char/map/web
    "rathena:rebuild".exec = "rm -f $DEVENV_ROOT/.devenv/state/rathena-packetver\n" + buildScript;
    "rathena:db-init".exec = "${initScript}"; # user + conf + schema (needs devenv up)
    # opt-in dev logins: player/player (group 0) and gmadmin/gmadmin (group 99)
    "rathena:dev-accounts".exec = "${devAccountsScript}";
    # live-safe mysqldump into backups/ (override dir with RATHENA_BACKUP_DIR)
    "rathena:backup".exec = "${backupScript}";
    "rathena:ping".exec = ''
      cd "$DEVENV_ROOT"
      ${pkgs.python3}/bin/python3 tools/rathena-ping.py
    '';
    # public-server setup, following https://github.com/rathena/rathena/wiki/connecting
    #   RATHENA_PUBLIC_IP=1.2.3.4 RATHENA_SERVER_NAME=MyServer \
    #     devenv tasks run rathena:configure
    "rathena:configure".exec = ''
      cd "$DEVENV_ROOT"
      ${pkgs.python3}/bin/python3 tools/rathena-configure.py
    '';
    # rotate secrets; generation happens automatically during 'devenv up'
    #   RATHENA_ROTATE="inter_pass" devenv tasks run rathena:secrets
    #   RATHENA_ROTATE=all          devenv tasks run rathena:secrets
    "rathena:secrets".exec = ''
      cd "$DEVENV_ROOT"
      case "''${RATHENA_ROTATE:-}" in
        "")    exec ${pkgs.python3}/bin/python3 tools/rathena-secrets.py ;;
        all)   exec ${pkgs.python3}/bin/python3 tools/rathena-secrets.py --rotate ;;
        *)     exec ${pkgs.python3}/bin/python3 tools/rathena-secrets.py --rotate $RATHENA_ROTATE ;;
      esac
    '';
    # set one account's password:
    #   RATHENA_ACCOUNT=player devenv tasks run rathena:passwd
    # devenv tasks take no arguments, hence the env var.
    "rathena:passwd".exec = ''
      cd "$DEVENV_ROOT"
      if [ -z "''${RATHENA_ACCOUNT:-}" ]; then
        echo "usage: RATHENA_ACCOUNT=<account> devenv tasks run rathena:passwd" >&2
        echo "   or: ./login-server --set-password <account>" >&2
        exit 1
      fi
      exec ./login-server --set-password "$RATHENA_ACCOUNT"
    '';
    # restore the database from a backup (destructive; see the script header)
    #   RATHENA_RESTORE_CONFIRM=yes devenv tasks run rathena:restore
    "rathena:restore".exec = "${pkgs.bash}/bin/bash $DEVENV_ROOT/tools/rathena-restore.sh";
    # restore the age identity on a new machine (key on stdin)
    "rathena:identity".exec = "${pkgs.bash}/bin/bash $DEVENV_ROOT/tools/rathena-identity.sh";
    # generate the operator peppers once and store them in secrets.age
    "rathena:peppers".exec = "${pkgs.bash}/bin/bash $DEVENV_ROOT/tools/rathena-peppers.sh";
    # pre-flight audit: connection, security and rate settings
    "rathena:check".exec = ''
      cd "$DEVENV_ROOT"
      export RATHENA_MYSQL_BIN=${mysqlBin}
      ${pkgs.python3}/bin/python3 tools/rathena-check.py
    '';
  };

  # --- processes: `devenv up` ----------------------------------------------
  # login-server runs build and initialization serially before it starts. The
  # other processes then form a manager-independent TCP readiness chain:
  # login -> char -> map, with backups also waiting for login.
  # ---------------------------------------------------------------------------
  # devenv test
  # ---------------------------------------------------------------------------
  # Starts MariaDB and the three servers, runs the operator command suite
  # against them, then shuts everything down.
  #
  #   devenv test
  #   RATHENA_TEST_DESTRUCTIVE=0 devenv test   skip the restore round trip
  enterTest = ''
    exec ${pkgs.bash}/bin/bash "$DEVENV_ROOT/tools/rathena-test.sh"
  '';

  processes.login-server.exec = ''
    cd "$DEVENV_ROOT"
    ${buildScript}
    ${initScript}
    exec ./login-server
  '';
  processes.char-server.exec = "cd $DEVENV_ROOT && ${waitDb} && ${waitTcp} 6900 && exec ./char-server";
  processes.map-server.exec = "cd $DEVENV_ROOT && ${waitDb} && ${waitTcp} 6121 && exec ./map-server";
  # Waiting for login-server also guarantees initialization has generated and
  # synchronized the credentials before the first backup reads them.
  processes.rathena-backup.exec =
    "cd $DEVENV_ROOT && ${waitDb} && ${waitTcp} 6900 && exec ${backupLoop}";
}
