#!/usr/bin/env python3
"""Print the node URI only in an authenticated Cloady container terminal."""
import os
import pathlib
import urllib.parse
import uuid

uid = str(uuid.UUID(pathlib.Path("/data/vless_uuid").read_text(encoding="ascii").strip()))
host = (os.environ.get("CLOADY_PRIMARY_HOST") or os.environ.get("CLOADY_DOMAIN") or "").strip().lower()
if not host:
    print("CLOADY_PRIMARY_HOST missing; copy your *.cloady.io hostname from the app page.")
    host = input("Public hostname: ").strip().lower()
if not host or "://" in host or "/" in host:
    raise SystemExit("Invalid hostname")
params = urllib.parse.urlencode({
    "encryption": "none",
    "security": "tls",
    "type": "ws",
    "host": host,
    "path": "/node",
    "sni": host,
})
print("\nImport URI:\nvless://" + uid + "@" + host + ":443?" + params + "#Cloady-Sing-box-Pre")
print("\nAddress: " + host + " | Port: 443 | TLS: on | WS path: /node")
if pathlib.Path("/data/ssh_enabled").exists():
    print("\nSSH enabled. Use the IPv6 and public TCP port displayed by Cloady:")
    print("ssh -6 -p <PUBLIC_TCP_PORT> nodeadmin@<CLOADY_IPV6>")
else:
    print("\nSSH disabled. Set SSH_PUBLIC_KEY in Cloady Environment and Redeploy to enable it.")
