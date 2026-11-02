#!/bin/sh
set -eu
umask 077
python3 /opt/cloady/setup.py
sing-box check -c /etc/sing-box/config.json
nginx -t -c /opt/cloady/nginx.conf
SSH_PID=""
  mkdir -p /data/ssh /run/sshd
  chmod 700 /data/ssh
  if [ ! -f /data/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /data/ssh/ssh_host_ed25519_key
  fi
  cat > /etc/ssh/sshd_config <<'SSHD'
Port 2222
AddressFamily any
HostKey /data/ssh/ssh_host_ed25519_key
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers nodeadmin
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
UsePAM no
Subsystem sftp internal-sftp
SSHD
  /usr/sbin/sshd -t
  /usr/sbin/sshd -D -e &
  SSH_PID=$!
nginx -c /opt/cloady/nginx.conf -g 'daemon off;' &
NGINX_PID=$!
sing-box run -c /etc/sing-box/config.json &
SB_PID=$!
shutdown() {
  kill "$NGINX_PID" "$SB_PID" 2>/dev/null || true
  if [ -n "$SSH_PID" ]; then kill "$SSH_PID" 2>/dev/null || true; fi
  wait "$NGINX_PID" "$SB_PID" 2>/dev/null || true
  if [ -n "$SSH_PID" ]; then wait "$SSH_PID" 2>/dev/null || true; fi
}
trap 'shutdown; exit 0' TERM INT
while :; do
  if ! kill -0 "$NGINX_PID" 2>/dev/null || ! kill -0 "$SB_PID" 2>/dev/null; then
    echo "A required service exited; stopping container." >&2
    shutdown
    exit 1
  fi
  if [ -n "$SSH_PID" ] && ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "SSH exited; stopping container." >&2
    shutdown
    exit 1
  fi
  sleep 5 &
  wait $! || true
done
