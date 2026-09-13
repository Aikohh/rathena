#!/usr/bin/env python3
"""Reachability check for an rAthena stack - no game client needed.

    ./rathena ping                    check the address the server advertises
    ./rathena ping 203.0.113.9        check a specific host
    ./rathena ping --local            check 127.0.0.1
    ./rathena ping --account u --password p    also do a real login
    ./rathena ping --password-encrypt           force <passwordencrypt> mode

Checks the three TCP ports and, with an account, performs the configured login
handshake. The reply carries the char-server address the client is
told to connect to next, which is the single most common thing to get wrong:
a server reachable on its WAN address can still hand out 127.0.0.1 and leave
every remote player stuck at the character screen.
"""
import argparse
import hashlib
import ipaddress
import os
import socket
import struct
import sys

PORTS = [("login-server", 6900), ("char-server", 6121), ("map-server", 5121)]


def say(*a):
    """devenv captures task stdout as JSON, so report on stderr."""
    print(*a, file=sys.stderr)


def config_value(root, relpath, key):
    """Read one effective value from a simple rAthena import file."""
    path = os.path.join(root, relpath)
    found = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith(f"{key}:"):
                    found = line.split(":", 1)[1].strip()
    except OSError:
        pass
    return found


def configured_host(root):
    """The char_ip the server advertises, straight from the deploy config."""
    return config_value(root, "conf/import/deploy_conf.txt", "char_ip")


def wire_password_enabled(root):
    return bool(config_value(root, "conf/import/pepper_conf.txt", "password_pepper"))


# Addresses a client outside the network can never reach. Deliberately not
# ipaddress.is_private, which also covers the documentation ranges
# (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and would call a test
# address "local", hiding exactly the case this is meant to catch.
UNROUTABLE = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",  # RFC 1918
    "100.64.0.0/10",                                   # carrier-grade NAT
    "169.254.0.0/16",                                  # link-local
)]


def is_local(addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False   # a hostname; assume it resolves somewhere routable
    return ip.is_loopback or any(ip in net for net in UNROUTABLE)


def check_port(host, name, port, timeout=3.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            say(f"  OK    {name:<13} {host}:{port} accepting connections")
            return True
    except OSError as exc:
        say(f"  FAIL  {name:<13} {host}:{port} {exc}")
        return False


def parse_char_servers(opcode, data):
    """Yield (ip, port, name) for each char-server the login-server advertises."""
    if opcode == 0x0AC4:
        head, size = 64, 160
    elif opcode == 0x0069:
        head, size = 47, 32
    else:
        return
    while head + size <= len(data):
        ip, port = struct.unpack("<IH", data[head:head + 6])
        name = data[head + 6:head + 26].split(b"\0")[0].decode(errors="replace")
        yield socket.inet_ntoa(struct.pack("<I", ip)), port, name
        head += size


def recv_exact(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ConnectionError("server closed the connection")
        data += part
    return data


def login_handshake(host, user, pw, packetver, password_encrypt=False, timeout=5.0):
    try:
        with socket.create_connection((host, 6900), timeout=timeout) as sock:
            if password_encrypt:
                sock.sendall(struct.pack("<H", 0x01DB))
                header = recv_exact(sock, 4)
                opcode, length = struct.unpack("<HH", header)
                if opcode != 0x01DC or length < 4:
                    raise ValueError(f"unexpected challenge reply 0x{opcode:04x}")
                challenge = recv_exact(sock, length - 4)
                digest = hashlib.md5(challenge + pw.encode()).digest()
                pkt = struct.pack(
                    "<HI24s16sB", 0x01DD, packetver,
                    user.encode()[:23].ljust(24, b"\0"), digest, 0x03,
                )
            else:
                pkt = struct.pack(
                    "<HI24s24sB", 0x0064, packetver,
                    user.encode()[:23].ljust(24, b"\0"),
                    pw.encode()[:23].ljust(24, b"\0"), 0x03,
                )
            sock.sendall(pkt)
            data = sock.recv(4096)
    except OSError as exc:
        say(f"  FAIL  login handshake: {exc}")
        return False

    if not data:
        say("  FAIL  login handshake: server closed the connection (packetver mismatch?)")
        return False

    opcode = struct.unpack("<H", data[:2])[0]

    if opcode in (0x006A, 0x083E):
        code = data[2] if len(data) > 2 else -1
        say(f"  FAIL  login handshake: rejected (packet 0x{opcode:04x}, reason {code})")
        return False

    if opcode not in (0x0069, 0x0AC4, 0x0AC9):
        say(f"  WARN  login handshake: unexpected reply 0x{opcode:04x} ({len(data)} bytes)")
        return False

    say(f"  OK    login handshake: accepted (packet 0x{opcode:04x})")

    servers = list(parse_char_servers(opcode, data))
    if not servers:
        say("  WARN  no char-server advertised in the reply")
        return False

    ok = True
    for ip, port, name in servers:
        # This is the address the client is sent to next. If the login-server
        # is reachable over the internet but hands out a private address, every
        # remote player stalls here with no error worth the name.
        if not is_local(host) and is_local(ip):
            say(f"  FAIL  advertised char-server '{name}' is {ip}:{port}")
            say(f"        remote clients cannot reach that. Fix with:")
            say(f"        set RATHENA_PUBLIC_IP in .env, then ./rathena configure")
            ok = False
        else:
            say(f"  OK    advertised char-server '{name}' is {ip}:{port}")
    return ok


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("host", nargs="?")
    ap.add_argument("--local", action="store_true", help="check 127.0.0.1")
    ap.add_argument("--account")
    ap.add_argument("--password")
    ap.add_argument("--password-encrypt", action="store_true")
    ap.add_argument("--packetver", type=int, default=20220406)
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        say(__doc__)
        return 0

    root = os.environ.get("DEVENV_ROOT", os.getcwd())
    env_host = os.environ.get("RATHENA_HOST")

    if args.local:
        host, source = "127.0.0.1", "loopback"
    elif args.host:
        host, source = args.host, "argument"
    elif env_host:
        host, source = env_host, "RATHENA_HOST"
    else:
        host = configured_host(root)
        source = "advertised char_ip"
        if not host:
            host, source = "127.0.0.1", "default"

    say(f"\nrAthena reachability check on {host}  ({source})")

    if not is_local(host):
        # Many routers do not loop a WAN connection back to the inside, so a
        # failure here can be NAT rather than the server.
        say("  note  run this from outside your network too: some routers do")
        say("        not route your own WAN address back in (NAT hairpinning),")
        say("        which fails here while remote players connect fine")

    ok = all([check_port(host, n, p) for n, p in PORTS])

    if args.account and args.password:
        encrypted = args.password_encrypt or wire_password_enabled(root)
        if encrypted:
            say("  note  login handshake uses <passwordencrypt>")
        ok = login_handshake(host, args.account, args.password, args.packetver, encrypted) and ok
    else:
        say("  (add --account U --password P to test a real login and see")
        say("   which char-server address the client is handed)")

    say("\nall reachable" if ok else "\nproblems found")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
