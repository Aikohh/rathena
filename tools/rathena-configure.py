#!/usr/bin/env python3
"""Configure an rAthena server for public use.

Implements the steps from https://github.com/rathena/rathena/wiki/connecting
without hand-editing anything, and only ever writes to conf/import/ so that
`git pull` never clobbers your settings (wiki: "Using the /conf/import/ folder").

  RATHENA_PUBLIC_IP     WAN address clients connect to. "auto" detects it.
                        Auto-detected if unset.
  RATHENA_SERVER_NAME   server_name / wisp_server_name. Default: rAthena
  RATHENA_LAN_SUBNET    e.g. 192.168.1.0/24, to let LAN clients connect too

Every managed setting lives inside a marked block, so re-running this is
idempotent and your own edits outside the block survive.
"""
import os
import re
import sys
import urllib.request


def out(*a):
    """devenv captures task stdout as JSON, so report on stderr."""
    print(*a, file=sys.stderr)

ROOT = os.environ.get("DEVENV_ROOT", "/workspaces/rathena")
DEPLOY_CONF = "conf/import/deploy_conf.txt"

IP_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


def fail(msg):
    out(f"error: {msg}")
    sys.exit(1)


def detect_public_ip():
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"):
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                ip = r.read().decode().strip()
                if IP_RE.match(ip):
                    return ip
        except Exception:
            continue
    return None


def main():
    public_ip = os.environ.get("RATHENA_PUBLIC_IP", "").strip()
    if not public_ip or public_ip.lower() == "auto":
        if public_ip:
            out("RATHENA_PUBLIC_IP=auto, detecting...")
        else:
            out("RATHENA_PUBLIC_IP not set, detecting...")
        public_ip = detect_public_ip()
        if not public_ip:
            fail("could not detect the public IP - set RATHENA_PUBLIC_IP")
    if not IP_RE.match(public_ip):
        fail(f"'{public_ip}' is not an IPv4 address")

    server_name = os.environ.get("RATHENA_SERVER_NAME", "rAthena").strip()
    if " " in server_name:
        fail("RATHENA_SERVER_NAME must not contain spaces (guild emblems break client-side)")

    lan_subnet = os.environ.get("RATHENA_LAN_SUBNET", "").strip()

    out(f"public IP   : {public_ip}")
    out(f"server name : {server_name}")
    out()

    # --- deployment addresses, kept out of version control -----------------
    # char_ip/map_ip are what the client is told to connect to: ALWAYS the WAN
    # IP. They are not secret, but they follow the machine rather than the
    # repository, so they live in a gitignored file both servers import.
    deploy_path = os.path.join(ROOT, DEPLOY_CONF)
    os.makedirs(os.path.dirname(deploy_path), exist_ok=True)
    with open(deploy_path, "w", encoding="utf-8") as fh:
        fh.write(
            "// Deployment addresses. GITIGNORED - specific to this machine.\n"
            "// Written by rathena:configure.\n"
            f"server_name: {server_name}\n"
            f"wisp_server_name: {server_name}\n"
            f"char_ip: {public_ip}\n"
            f"map_ip: {public_ip}\n"
        )
    out(f"  wrote  {DEPLOY_CONF} (gitignored)")

    # --- LAN clients, if the operator has any ------------------------------
    if lan_subnet:
        if "/" not in lan_subnet:
            fail("RATHENA_LAN_SUBNET must look like 192.168.1.0/24")
        net, bits = lan_subnet.split("/")
        bits = int(bits)
        mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
        mask_str = ".".join(str((mask >> s) & 0xFF) for s in (24, 16, 8, 0))
        path = os.path.join(ROOT, "conf/subnet_athena.conf")
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
        line = f"subnet: {mask_str}:{net}:{net}"
        if line not in body:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(f"\n// added by rathena:configure - LAN clients\n{line}\n")
            out(f"  wrote  conf/subnet_athena.conf ({line})")
        else:
            out("  ok     conf/subnet_athena.conf already has the LAN subnet")

    out()
    out("Configured. Restart with 'devenv up', then:")
    out("  ./rathena check")


if __name__ == "__main__":
    main()
