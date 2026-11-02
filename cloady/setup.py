#!/usr/bin/env python3
"""Build sing-box config and optional public-key-only SSH from environment."""
import base64
import json
import os
import pathlib
import pwd
import uuid

os.umask(0o077)
DATA = pathlib.Path("/data")
DATA.mkdir(mode=0o700, parents=True, exist_ok=True)
uid_file = DATA / "vless_uuid"
provided = os.environ.get("VLESS_UUID", "").strip()
if provided:
    try:
        uid = str(uuid.UUID(provided))
    except ValueError as exc:
        raise SystemExit("VLESS_UUID must be a valid UUID") from exc
elif uid_file.exists():
    try:
        uid = str(uuid.UUID(uid_file.read_text(encoding="ascii").strip()))
    except ValueError as exc:
        raise SystemExit("Stored UUID invalid: fix /data/vless_uuid") from exc
else:
    uid = str(uuid.uuid4())
uid_file.write_text(uid + "\n", encoding="ascii")
uid_file.chmod(0o600)

config = {
    "log": {"level": "warn", "timestamp": True},
    "inbounds": [{
        "type": "vless", "tag": "vless-in",
        "listen": "127.0.0.1", "listen_port": 10000,
        "users": [{"uuid": uid}],
        "transport": {"type": "ws", "path": "/node"}
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"final": "direct"}
}
conf_path = pathlib.Path("/etc/sing-box/config.json")
conf_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
conf_path.chmod(0o600)

key_input = os.environ.get("SSH_PUBLIC_KEY", "").strip()
flag = DATA / "ssh_enabled"
if key_input:
    keys = []
    allowed = ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521")
    for line in key_input.splitlines():
        fields = line.strip().split()
        if not fields:
            continue
        if len(fields) < 2 or fields[0] not in allowed:
            raise SystemExit("SSH_PUBLIC_KEY must be a plain OpenSSH public key")
        try:
            base64.b64decode(fields[1], validate=True)
        except Exception as exc:
            raise SystemExit("Invalid SSH_PUBLIC_KEY base64") from exc
        keys.append(fields[0] + " " + fields[1])
    if not keys:
        raise SystemExit("No valid SSH_PUBLIC_KEY supplied")
    auth = pathlib.Path("/home/nodeadmin/.ssh/authorized_keys")
    auth.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    auth.write_text("\n".join(keys) + "\n", encoding="ascii")
    account = pwd.getpwnam("nodeadmin")
    os.chown(auth.parent, account.pw_uid, account.pw_gid)
    os.chown(auth, account.pw_uid, account.pw_gid)
    auth.parent.chmod(0o700)
    auth.chmod(0o600)
    flag.write_text("1\n", encoding="ascii")
else:
    flag.unlink(missing_ok=True)
    pathlib.Path("/home/nodeadmin/.ssh/authorized_keys").unlink(missing_ok=True)
print("Configuration generated. SSH is " + ("enabled." if key_input else "disabled.") + " Credentials omitted.")
