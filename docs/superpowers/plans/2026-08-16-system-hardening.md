# Sing-box-Pre System Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the Linux VPS installer and manager without changing the existing proxy data path, node formats, or deployed endpoint identities.

**Architecture:** Keep `sing-box.sh` as the public entry point, but introduce small, testable Bash helpers for validation, atomic state changes, local management, subscription publication, and WARP transactions. Coordinate with Pre-cfy through one lock path and one permission contract; all production mutations are staged, checked, and rolled back on failure.

**Tech Stack:** Bash, jq, curl, systemd/OpenRC, Nginx, sing-box CLI, iptables/ip6tables/firewalld, shell regression tests.

---

## File map

- Modify: `sing-box.sh` — production installer, manager, subscriptions, routing, Argo and WARP behavior.
- Modify: `README.md` — supported ports, offline manager, cfy contract and migration notes.
- Modify: `tests/test_warp_rotation.sh` — dynamic WARP transaction coverage.
- Create: `tests/test_install_safety.sh` — ports, stacks, package and firewall behavior.
- Create: `tests/test_local_manager_and_secrets.sh` — local `sb`, symlinks, modes, Argo and proxy credential handling.
- Create: `tests/test_route_and_nat_safety.sh` — route.final rollback and exact port-hop deletion.
- Create: `tests/test_subscription_contract.sh` — shared lock, ownership, permissions and atomic publication.
- Create: `tests/test_subscription_lifecycle.sh` — Nginx isolation and Cloudflare rollback semantics.

### Task 1: Safe install, explicit ports, stack-aware listeners and narrow firewall rules

**Files:**
- Modify: `sing-box.sh` functions `manage_packages`, `allow_port`, `install_singbox`, `add_nginx_conf`, `auto_install`.
- Create: `tests/test_install_safety.sh`.

- [ ] **Step 1: Write the failing install-safety test**

Create a Bash test that extracts the new helpers and asserts these exact cases:

```bash
assert_fail validate_port_value '' REALITY_PORT
assert_fail validate_port_value 0 REALITY_PORT
assert_fail validate_port_value 65536 REALITY_PORT
assert_ok validate_port_value 443 REALITY_PORT

PORT=65533 TUIC_PORT='' HY2_PORT='' NGINX_PORT=''
assert_fail resolve_service_ports

PORT=12000 NGINX_PORT=23001 TUIC_PORT=23003 HY2_PORT=23005 ARGO_PORT=18001
assert_ok resolve_service_ports
[ "$vless_port,$nginx_port,$tuic_port,$hy2_port,$argo_port" = '12000,23001,23003,23005,18001' ]

firewall-cmd() { printf '%s\n' "$*" >>"$CALL_LOG"; }
allow_port 23001 tcp
! grep -q -- '--set-target\|--set-policy' "$CALL_LOG"
grep -q -- '--add-port=23001/tcp' "$CALL_LOG"
```

Mock `apt`, `dnf`, `yum` and `apk`; assert no call contains `upgrade`, `full-upgrade` or `dist-upgrade`. Mock stack probes and assert `get_listener_address 1 0` prints `0.0.0.0`, `get_listener_address 0 1` prints `::`, and dual stack prints `::` only when `net.ipv6.bindv6only=0`.

- [ ] **Step 2: Run the new test and verify RED**

Run on a Linux shell with jq:

```bash
bash tests/test_install_safety.sh
```

Expected: non-zero with `validate_port_value: command not found` or the existing firewalld target assertion failing.

- [ ] **Step 3: Add minimal production helpers and use them before configuration writes**

Add these interfaces to `sing-box.sh`:

```bash
validate_port_value() {
    local value="$1" label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || {
        echo "${label} 必须是 1-65535 的整数。" >&2
        return 1
    }
}

resolve_service_ports() {
    vless_port="${REALITY_PORT:-$PORT}"
    nginx_port="${NGINX_PORT:-$((PORT + 1))}"
    tuic_port="${TUIC_PORT:-$((PORT + 2))}"
    hy2_port="${HY2_PORT:-$((PORT + 3))}"
    argo_port="${ARGO_PORT:-8001}"
    local label value seen=' '
    for label in vless nginx tuic hy2 argo; do
        eval "value=\${${label}_port}"
        validate_port_value "$value" "${label}_port" || return 1
        case "$seen" in *" $value "*) echo "端口重复: $value" >&2; return 1;; esac
        seen="${seen}${value} "
    done
}

get_listener_address() {
    local has_v4="$1" has_v6="$2" bindv6only="${3:-0}"
    if [ "$has_v6" = 1 ] && { [ "$has_v4" = 0 ] || [ "$bindv6only" = 0 ]; }; then
        printf '%s\n' '::'
    else
        printf '%s\n' '0.0.0.0'
    fi
}
```

Call `resolve_service_ports` before downloads or writes. Persist validated non-secret settings in `/etc/sing-box/install.env` with mode `0600`, and load them before applying defaults on later `sb` runs. Generate Nginx IPv6 listen directives only when IPv6 sockets are available.

Remove all package-manager full-upgrade calls; keep metadata refresh and missing-package installation. Remove firewalld target changes and iptables policy changes; add only exact port rules. Make `auto_install` check every critical return value and return non-zero before printing success.

- [ ] **Step 4: Run install safety and existing tests**

```bash
bash tests/test_install_safety.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
```

Expected: install safety passes; all existing tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add sing-box.sh tests/test_install_safety.sh
git commit -m "fix: harden install ports and network setup"
```

### Task 2: Local offline manager and secret-safe Argo/proxy handling

**Files:**
- Modify: `sing-box.sh` functions `create_shortcut`, fixed-Argo writers, config writers and Socks/HTTP outbound probe.
- Create: `tests/test_local_manager_and_secrets.sh`.

- [ ] **Step 1: Write the failing local-manager and secrets test**

The test must build a temporary install root and assert:

```bash
create_shortcut "$fixture"
! grep -q 'raw.githubusercontent.com.*sing-box.sh' "$fixture/etc/sing-box/sb.sh"
grep -q '/usr/local/lib/sing-box-pre/sing-box.sh' "$fixture/etc/sing-box/sb.sh"
[ "$(readlink "$fixture/usr/local/bin/sing-box")" = '/etc/sing-box/sing-box' ]

write_fixed_argo_credentials token 'secret-value' "$fixture"
[ "$(stat -c %a "$fixture/etc/sing-box/argo.token")" = 600 ]
! grep -R -q 'secret-value' "$fixture/etc/systemd/system" "$fixture/etc/init.d"
```

Mock `curl` and call the outbound probe with `http://alice:password@example.test:3128`; assert the URL appears only after `--proxy` and never in a destination query string or request body. Generate `inbounds.json`, `outbounds.json` and `tunnel.json` under umask 022 and assert mode 600.

Create a fixed-Tunnel fixture, dispatch `sb -r`, and assert it returns a clear non-zero result without restarting Argo or attempting to parse a `trycloudflare.com` hostname.

- [ ] **Step 2: Run the test and verify RED**

```bash
bash tests/test_local_manager_and_secrets.sh
```

Expected: failure because the wrapper downloads Raw main, the binary link points at the wrapper, or token appears in the unit.

- [ ] **Step 3: Implement a local manager with atomic explicit update**

Install the current script to `/usr/local/lib/sing-box-pre/sing-box.sh` using `install -m 700`. Write `/etc/sing-box/sb.sh` as:

```bash
#!/bin/bash
set -e
exec /usr/local/lib/sing-box-pre/sing-box.sh "$@"
```

Point `/usr/local/bin/sb` and `/usr/bin/sb` to that wrapper, and `/usr/local/bin/sing-box` to `/etc/sing-box/sing-box`. Add an explicit update helper that downloads to the installed directory, requires `bash -n`, preserves `.previous`, and only then renames the new file.

Set `umask 077` before any secret generation. Store fixed Tunnel token in `/etc/sing-box/argo.token` mode 600 and configure cloudflared to read the file through its token-file option; store JSON credentials mode 600. Do not print fixed credentials after input, and use `read -rs` for interactive token entry.

Replace the third-party proxy-check URL with local:

```bash
curl -fsS --proxy "$proxy_url" --connect-timeout 5 --max-time 10 \
    https://www.cloudflare.com/cdn-cgi/trace -o /dev/null
```

Route command-line `-r` through the same Tunnel-type guard used by the interactive menu: refresh is allowed only for a temporary Tunnel and must not restart a fixed Tunnel.

- [ ] **Step 4: Verify Task 2**

```bash
bash tests/test_local_manager_and_secrets.sh
bash -n sing-box.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
```

Expected: all commands exit 0 and the test output contains no secret.

- [ ] **Step 5: Commit Task 2**

```bash
git add sing-box.sh tests/test_local_manager_and_secrets.sh
git commit -m "fix: keep management local and protect credentials"
```

### Task 3: Transactional proxy routing and exact HY2 NAT cleanup

**Files:**
- Modify: `sing-box.sh` proxy deletion and Hysteria2 port-hopping functions.
- Create: `tests/test_route_and_nat_safety.sh`.

- [ ] **Step 1: Write route and NAT regression tests**

Use fixture JSON where `route.final` and one rule reference `proxy-a`. Invoke the deletion helper and assert the staged config changes `route.final` to `direct`, removes rules that target `proxy-a`, and removes only the matching outbound. Inject a failed config check and assert byte-for-byte restoration of route/outbounds.

Mock iptables with an existing unrelated PREROUTING rule and record all calls. Add then remove HY2 hopping and assert no call contains `-F PREROUTING`; assert deletion uses the script chain/comment and leaves the unrelated rule untouched.

- [ ] **Step 2: Run the test and verify RED**

```bash
bash tests/test_route_and_nat_safety.sh
```

Expected: failure on dangling `route.final` and detection of `-F PREROUTING`.

- [ ] **Step 3: Implement staged route mutation and owned NAT rules**

Create `mutate_proxy_transaction tag replacement` that copies route/outbounds to same-directory temporary files, applies jq mutations to both, runs `/etc/sing-box/sing-box check -C "$conf_dir"` against staged files, atomically replaces both, restarts and checks active state, and restores both backups on any failure.

Create a dedicated `PRENET_HY2` chain per address family, jump to it with comment `prenet-hy2`, and delete only that jump and chain. Never change unrelated policies or flush a built-in chain.

- [ ] **Step 4: Run focused and full tests**

```bash
bash tests/test_route_and_nat_safety.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
```

Expected: all pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add sing-box.sh tests/test_route_and_nat_safety.sh
git commit -m "fix: make routing and port hopping transactional"
```

### Task 4: Shared atomic subscription contract with Pre-cfy

**Files:**
- Modify: `sing-box.sh` subscription generators and Argo/UUID update paths.
- Create: `tests/test_subscription_contract.sh`.

- [ ] **Step 1: Write failing contract tests**

Create fixtures for `url.txt` and `cfy-url.txt` containing duplicates. Invoke the publication function concurrently from two shells. Assert:

```bash
[ "$(stat -c %a "$dir/url.txt")" = 600 ]
[ "$(stat -c %a "$dir/cfy-url.txt")" = 600 ]
[ "$(stat -c %a "$dir/all-url.txt")" = 600 ]
[ "$(stat -c %a "$dir/all-sub.txt")" = 600 ]
[ "$(stat -c %a "$dir/sub.txt")" = 644 ]
cmp "$dir/all-url.txt" <(base64 -d "$dir/all-sub.txt")
cmp "$dir/all-url.txt" <(base64 -d "$dir/sub.txt")
[ "$(sort "$dir/all-url.txt" | uniq -d | wc -l)" -eq 0 ]
```

Assert both repositories use `/etc/sing-box/.subscription.lock`, and UUID/Argo updates rewrite only `url.txt` before republishing; old cfy endpoints must not be copied into `url.txt`.

- [ ] **Step 2: Run the test and verify RED**

```bash
bash tests/test_subscription_contract.sh
```

Expected: failure on missing shared lock, 0644 internal files, or inconsistent concurrent output.

- [ ] **Step 3: Implement one publication function**

Add:

```bash
with_subscription_lock() {
    local lock_file="${SUBSCRIPTION_LOCK_FILE:-$conf_dir/.subscription.lock}"
    mkdir -p "$(dirname "$lock_file")"
    exec {subscription_lock_fd}>"$lock_file" || return 1
    flock -x "$subscription_lock_fd" || return 1
    "$@"
}
```

The locked publisher must normalize exact URL lines, deduplicate `url.txt` plus `cfy-url.txt` into one same-directory temporary file, generate both Base64 outputs from that file, set `600/600/644`, then rename all outputs while holding the lock. Keep the old generation if staging fails. Use a mkdir lock fallback with bounded retries when `flock` is unavailable.

- [ ] **Step 4: Verify Task 4**

```bash
bash tests/test_subscription_contract.sh
for test_file in tests/test_subscription_*.sh; do bash "$test_file"; done
```

Expected: all subscription tests pass.

- [ ] **Step 5: Commit Task 4**

```bash
git add sing-box.sh tests/test_subscription_contract.sh
git commit -m "fix: publish subscriptions under a shared contract"
```

### Task 5: Complete WARP transaction and reliable unlock detection

**Files:**
- Modify: `sing-box.sh` WARP registration, candidate proxy, activation, cache and detector functions.
- Modify: `tests/test_warp_rotation.sh`.

- [ ] **Step 1: Extend WARP tests with executable fixtures**

Use extracted functions and PATH-prepended mock `curl`, `sing-box`, `systemctl` and `jq`. Cover:

- first registration returns parseable endpoint JSON on stdout while progress is only stderr;
- hard maximum of five candidates regardless of environment input;
- missing old active IP aborts automatic rotation rather than accepting an unverifiable candidate;
- candidate IP must differ before and after activation;
- production service must become active and selected unlock checks must pass after activation;
- INT and TERM restore account/state/endpoint and return 130/143;
- rollback failure returns a distinct fatal code, keeps the candidate directory, and stops the loop;
- old device DELETE failure stores a 600 pending-delete credential and later retry removes it;
- failed status probes are cached for the short failure TTL;
- custom `direct` outbound is byte-for-byte preserved.

Add detector fixtures: Netflix two-title full/originals/ambiguous; Disney assertion-only, token forbidden, supported true/false; ChatGPT web 403 plus empty iOS, blocked body, `(1)/(2)`, normal pass; Gemini generic 200, consent/CAPTCHA, unsupported, positive application marker.

- [ ] **Step 2: Run WARP tests and verify RED**

```bash
bash tests/test_warp_rotation.sh
```

Expected: non-zero on first-registration JSON pollution, transaction signal handling or detector false positives.

- [ ] **Step 3: Implement the minimal WARP fixes**

Redirect progress output in data-returning functions to stderr. Use a fixed local `max_candidates=5`. Require old IP before automatic rotation; after installing a candidate, reprobe the production outbound and require a new IP plus the selected unlock result.

Represent activation outcomes as `0=committed`, `1=rejected with complete rollback`, `2=rollback incomplete`. The caller must stop immediately on 2 and preserve the candidate registration and recovery path.

Install transaction-local INT/TERM traps that restore backups, restart and verify the production service, clean only owned temporary paths, and return the correct signal code. Add pending-delete storage and retry.

For detectors, accept only positive structured evidence; return `2` for network/markup ambiguity. Netflix requires valid region evidence and two-title logic. Disney requires token exchange and `inSupportedLocation=true`. ChatGPT never treats web 403 or empty iOS response as unlocked. Gemini requires the positive application bootstrap marker on `gemini.google.com`.

- [ ] **Step 4: Verify WARP behavior**

```bash
bash tests/test_warp_rotation.sh
bash tests/test_warp_routing.sh
bash -n sing-box.sh
```

Expected: all pass with no credentials in captured stdout/stderr.

- [ ] **Step 5: Commit Task 5**

```bash
git add sing-box.sh tests/test_warp_rotation.sh
git commit -m "fix: make WARP rotation transactional and verifiable"
```

### Task 6: Isolated subscription lifecycle and Cloudflare rollback

**Files:**
- Modify: `sing-box.sh` subscription enable/disable/token/HTTPS and Cloudflare DNS rollback functions.
- Create: `tests/test_subscription_lifecycle.sh`.

- [ ] **Step 1: Write failing lifecycle tests**

Mock an unrelated Nginx virtual host and assert disabling the node subscription removes only the Sing-box server block and calls reload, never `systemctl stop nginx` or `pkill nginx`.

Inject failure after HTTP token config staging and after HTTPS route deletion; assert the old URL/state remain usable. Mock Cloudflare HTTP 200 with `{"success":false}` and assert rollback returns non-zero and writes a 600 recovery record.

- [ ] **Step 2: Run and verify RED**

```bash
bash tests/test_subscription_lifecycle.sh
```

Expected: failure because current disable stops Nginx or success:false is accepted.

- [ ] **Step 3: Implement isolated lifecycle transactions**

Back up the dedicated server block and subscription state, stage the new block/state, run `nginx -t`, reload, and commit state last. On any failure restore both and reload the known-good block. Disabling removes only the dedicated block or stops only `sing-box-subscription.service`.

Parse every Cloudflare mutation response with `jq -e '.success == true'`. Save exact recovery action and non-secret identifiers when remote rollback is incomplete.

- [ ] **Step 4: Verify lifecycle and full suite**

```bash
bash tests/test_subscription_lifecycle.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
```

Expected: every test exits 0.

- [ ] **Step 5: Commit Task 6**

```bash
git add sing-box.sh tests/test_subscription_lifecycle.sh
git commit -m "fix: isolate subscription and DNS lifecycle changes"
```

### Task 7: Documentation, compatibility matrix and final verification

**Files:**
- Modify: `README.md`.
- Modify: `.github/workflows/test.yml` if needed to run every `tests/test_*.sh` file.

- [ ] **Step 1: Add documentation assertions before editing docs**

Add grep assertions to the most relevant tests for documented variables `REALITY_PORT`, `NGINX_PORT`, `TUIC_PORT`, `HY2_PORT`, `ARGO_PORT`, local offline `sb`, shared lock and `600/644` permissions. Run them and confirm failure on missing documentation.

- [ ] **Step 2: Update README and workflow**

Document defaults, non-contiguous NAT examples, single/dual-stack behavior, offline management, explicit updates, cfy ownership, health-check cost, migration safety and uninstall boundaries. Ensure CI invokes every shell test under a Linux image with jq and curl.

- [ ] **Step 3: Run fresh final verification**

```bash
bash -n sing-box.sh
git diff --check
for test_file in tests/test_*.sh; do echo "RUN $test_file"; bash "$test_file" || exit 1; done
```

On the current Debian VPS staging directory also run:

```bash
/etc/sing-box/sing-box check -C /etc/sing-box/conf
systemctl is-active sing-box argo sing-box-subscription
```

Expected: syntax/check exit 0, every test passes, and all three services print `active` before deployment proceeds.

- [ ] **Step 4: Commit Task 7**

```bash
git add README.md .github/workflows tests sing-box.sh
git commit -m "docs: document hardened VPS compatibility"
```
