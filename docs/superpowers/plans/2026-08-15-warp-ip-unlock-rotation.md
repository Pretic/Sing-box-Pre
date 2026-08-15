# WARP IP Rotation and Multi-Service Unlock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe built-in WARP status, one-shot identity rotation, and bounded multi-service IP selection for Netflix, Disney+, ChatGPT, and Gemini without changing the host network stack.

**Architecture:** Refactor per-VPS registration so it can create isolated candidate state, probe each candidate through a temporary localhost-only sing-box proxy, and transactionally activate only a validated candidate. Cache sanitized probe state for the main menu and preserve every existing route, outbound, endpoint, node, subscription, and Argo setting.

**Tech Stack:** Bash, jq, curl, sing-box CLI, systemd/OpenRC, existing shell regression suite.

**User override:** Do not create Git commits and do not push GitHub in this iteration. Commit steps normally required by the planning workflow are intentionally omitted.

---

## File structure

- Modify `sing-box.sh`: registration destination support, candidate probing, platform detectors, transactional activation, menu actions, and cached main-menu status.
- Create `tests/test_warp_rotation.sh`: isolated tests for secret redaction, bounded selection, detector aggregation, activation, rollback, and temporary-process cleanup.
- Modify `tests/test_warp_routing.sh`: assert the expanded WARP submenu and preserve existing routing coverage.
- Modify `README.md`: document the new menu, four detectors, five-attempt bound, state location, limitations, and absence of system WARP.
- Keep `docs/superpowers/specs/2026-08-15-warp-ip-unlock-rotation-design.md`: approved design source.
- Keep this plan uncommitted until the user requests the later combined GitHub update.

### Task 1: Registration candidates and transactional activation

**Files:**
- Modify: `sing-box.sh:3210-3450`
- Create: `tests/test_warp_rotation.sh`

- [ ] **Step 1: Write failing registration/activation tests**

Create fixtures with an active endpoint/account and a different candidate endpoint/account. Assert:

```bash
generate_unique_warp_identity "$candidate_dir"
[[ -s "$candidate_dir/account.json" ]]
[[ -s "$candidate_dir/endpoint.json" ]]
[[ ! -e "$conf_dir/warp/account.json" ]]

activate_warp_candidate "$candidate_dir"
jq -e '.endpoints | any(.tag == "wireguard-out" and .private_key == "candidate-private")' \
  "$conf_dir/endpoints.json" >/dev/null
cmp -s "$candidate_dir/account.json" "$conf_dir/warp/account.json"
```

Mock validation and restart failure separately and assert the original three active files are byte-identical after rollback.

- [ ] **Step 2: Run the new test and verify it fails**

Run from WSL or the target VPS:

```bash
bash tests/test_warp_rotation.sh
```

Expected: failure because destination-aware generation and `activate_warp_candidate` do not exist.

- [ ] **Step 3: Make identity generation destination-aware**

Change the function contract to:

```bash
generate_unique_warp_identity() {
    local state_dir="${1:-${conf_dir}/warp}"
    # Existing local key generation and registration flow remains unchanged.
    # All temporary and final files are written below state_dir.
}
```

Keep the default path for first-use backward compatibility. Require the resolved candidate path to remain below `${conf_dir}/warp`, create it mode 0700, and keep account/endpoint files mode 0600.

- [ ] **Step 4: Add transactional candidate activation**

Implement:

```bash
activate_warp_candidate() {
    local candidate_dir="$1"
    local active_dir="${conf_dir}/warp"
    local endpoint_file="${conf_dir}/endpoints.json"
    local backup_dir endpoint_json endpoint_tmp
    # Validate candidate files first.
    # Back up active account.json, endpoint.json, and endpoints.json.
    # Install candidate state and replace only tag=wireguard-out.
    # Run validate_singbox_config and restart_singbox_checked.
    # Restore all backups and restart the old config on any failure.
}
```

Do not change `route.json` or `outbounds.json`. After successful restart, invoke the committed endpoint probe; a failed post-activation probe triggers rollback.

- [ ] **Step 5: Run focused tests**

```bash
bash tests/test_warp_rotation.sh
```

Expected: registration destination and activation/rollback cases pass.

### Task 2: Candidate proxy and WARP trace probing

**Files:**
- Modify: `sing-box.sh` immediately after WARP endpoint validation helpers
- Modify: `tests/test_warp_rotation.sh`

- [ ] **Step 1: Add failing probe lifecycle tests**

Mock the sing-box binary and curl. Assert a probe:

```bash
start_warp_candidate_proxy "$candidate_endpoint"
[[ "$WARP_PROBE_PROXY" == socks5h://127.0.0.1:* ]]
probe_warp_trace "$WARP_PROBE_PROXY"
[[ "$WARP_PROBE_IP" == 104.28.1.2 ]]
[[ "$WARP_PROBE_COLO" == LAX ]]
[[ "$WARP_PROBE_STATE" == on ]]
stop_warp_candidate_proxy
! kill -0 "$WARP_PROBE_PID" 2>/dev/null
```

Also assert the temporary config/log directory is removed on success, curl failure, sing-box early exit, `INT`, and `TERM`.

- [ ] **Step 2: Verify tests fail**

```bash
bash tests/test_warp_rotation.sh
```

Expected: probe lifecycle functions are missing.

- [ ] **Step 3: Implement localhost-only temporary proxy**

Add functions with global outputs:

```bash
start_warp_candidate_proxy <endpoint-json>
stop_warp_candidate_proxy
probe_warp_trace <socks5h-url>
```

Choose an unused high TCP port by asking the OS/listener tools, bind only `127.0.0.1`, build a minimal config containing one mixed inbound and the candidate `wireguard-out`, run `sing-box check`, then start the process. Use a cleanup trap that chains/restores any previous trap rather than replacing unrelated script cleanup.

Parse only these trace fields:

```text
ip=
loc=
colo=
warp=on|plus
```

Use `--connect-timeout 5 --max-time 12`; never print endpoint private material.

- [ ] **Step 4: Run focused tests**

```bash
bash tests/test_warp_rotation.sh
```

Expected: lifecycle, parsing, and cleanup cases pass.

### Task 3: Four unlock detectors and bounded selection

**Files:**
- Modify: `sing-box.sh` after trace probing helpers
- Modify: `tests/test_warp_rotation.sh`

- [ ] **Step 1: Add table-driven failing detector tests**

Mock curl bodies/status codes for each detector and assert normalized results:

```text
pass        -> return 0, status=unlocked
restricted  -> return 1, status=restricted
ambiguous   -> return 2, status=检测失败
network     -> return 2, status=检测失败
```

Cover Netflix full/originals-only, Disney supported/unsupported, ChatGPT full/web-only/blocked, and Gemini available/unsupported/ambiguous.

- [ ] **Step 2: Verify detector tests fail**

```bash
bash tests/test_warp_rotation.sh
```

Expected: detector functions are missing.

- [ ] **Step 3: Implement sequential detectors**

Add:

```bash
check_unlock_netflix <proxy>
check_unlock_disney <proxy>
check_unlock_chatgpt <proxy>
check_unlock_gemini <proxy>
run_selected_unlock_checks <proxy> <selection-string>
```

Use the approved detection semantics, a browser user-agent, no insecure TLS bypass, short timeouts, and sequential requests to keep 1-core VPS load low. `run_selected_unlock_checks` returns success only when every selected detector returns full pass; ChatGPT web-only is displayed but fails strict mode.

- [ ] **Step 4: Add failing bounded-selector tests**

Inject mock callbacks for identity creation, trace probing, detector aggregation, deletion, and activation. Assert:

```bash
WARP_MAX_CANDIDATES=5 auto_select_warp_candidate 1234
[[ "$GENERATE_CALLS" -le 5 ]]
[[ "$ACTIVATE_CALLS" -eq 1 ]]
```

Cover same-IP rejection, WARP-off rejection, one selected-service failure, fifth-candidate success, all-five failure, and preservation of the active identity.

- [ ] **Step 5: Implement bounded automatic selection**

Add `auto_select_warp_candidate <selection>` with a hard maximum of five. Record the active IP before the loop, create each candidate in a unique directory, probe and test it, delete rejected Cloudflare registrations when credentials allow, remove local candidate state, and wait `2, 4, 6, 8` seconds between attempts. Activate only a passing candidate.

- [ ] **Step 6: Run focused tests**

```bash
bash tests/test_warp_rotation.sh
```

Expected: every detector and selector case passes, and no test leaves a process or temporary directory.

### Task 4: Status cache and menus

**Files:**
- Modify: `sing-box.sh:3696-3750` and main-menu status block near `menu()`
- Modify: `tests/test_warp_rotation.sh`
- Modify: `tests/test_warp_routing.sh`

- [ ] **Step 1: Add failing status/menu tests**

Assert the public script contains:

```text
---WARP 状态:
5. 查看内置 WARP 状态及解锁情况
6. 更换内置 WARP 身份/IP
7. 自动优选 WARP IP（多平台解锁）
```

Fixture tests cover `not configured`, `running`, and `degraded`. Capture status output and assert it does not contain fixture private keys, account tokens, client IDs, or reserved byte values.

- [ ] **Step 2: Verify status/menu tests fail**

```bash
bash tests/test_warp_rotation.sh
bash tests/test_warp_routing.sh
```

Expected: new status/menu assertions fail while old routing tests remain green.

- [ ] **Step 3: Implement sanitized status cache**

Store mode-0600 `${conf_dir}/warp/status.json` with only:

```json
{"checked_at":0,"ip":"","loc":"","colo":"","warp":"","unlock":{}}
```

Never copy registration credentials into the cache. Refresh it after an explicit status check, successful candidate probe/activation, or when older than five minutes. Main-menu display reads the cache; at most one short probe is triggered per five-minute window. Map absent endpoint to `not configured`, successful recent `warp=on|plus` to `running`, and a valid endpoint with a failed recent probe to `degraded`.

- [ ] **Step 4: Implement submenu actions**

Wire actions:

```bash
5 -> show_warp_status_and_unlocks
6 -> rotate_warp_identity_once
7 -> prompt selections; auto_select_warp_candidate
```

The selection prompt accepts `1234`, defaults to all four, rejects other characters, and labels `1 Netflix / 2 Disney+ / 3 ChatGPT / 4 Gemini`.

- [ ] **Step 5: Run focused tests**

```bash
bash tests/test_warp_rotation.sh
bash tests/test_warp_routing.sh
```

Expected: all status, secrecy, menu, and existing routing tests pass.

### Task 5: Documentation and full local regression

**Files:**
- Modify: `README.md:WARP 分流`
- Verify: all `tests/*.sh`

- [ ] **Step 1: Update README**

Document the three new operations, four detectors, strict all-selected rule, five-attempt cap, inability to guarantee a new country/IP, no background daemon, no system WARP, and correct state path `/etc/sing-box/conf/warp/`.

- [ ] **Step 2: Run syntax checks**

```bash
bash -n sing-box.sh
bash -n tests/test_warp_rotation.sh
```

Expected: no output and exit 0.

- [ ] **Step 3: Run the full shell suite**

```bash
for test_file in tests/*.sh; do bash "$test_file"; done
```

Expected: every test exits 0, including subscription, Argo, cfy, menu, WARP routing, and WARP rotation suites.

- [ ] **Step 4: Inspect the uncommitted diff**

```bash
git diff --check
git status --short --branch
git diff --stat
```

Expected: only the approved script, tests, README, spec, and plan are modified/untracked; branch remains `main...origin/main` with no new commit.

### Task 6: Sync and verify the current VPS

**Files:**
- Deploy: local `sing-box.sh` to `/usr/local/lib/sing-box-pre/sing-box.sh`
- Preserve: `/etc/sing-box/conf`, `/etc/sing-box/conf/warp`, `/etc/sing-box/url.txt`, subscription files, Argo/cloudflared state

- [ ] **Step 1: Capture the pre-deployment state**

Record script hash, config check, service states, route rule tags, active WARP ID/IP/colo, native IP, file permissions, and open temporary listeners.

- [ ] **Step 2: Create a recoverable VPS backup**

Create one timestamped mode-0700 directory under `/etc/sing-box/backups/`, containing the installed management script and active WARP/config files. Validate the resolved backup path before copying.

- [ ] **Step 3: Deploy without changing live routing**

Install the new script mode 0700, run `bash -n`, run the script-extracted unit tests if practical, and confirm that deployment alone does not restart sing-box or modify configuration hashes.

- [ ] **Step 4: Exercise status and one isolated candidate probe**

Use the new status action to verify current WARP health and all four platform results. Run one candidate probe without activation first; confirm the production endpoint, route file, native IP, and service PID remain unchanged.

- [ ] **Step 5: Exercise bounded automatic selection**

Run the approved selector with all four services and a five-candidate cap. If no candidate qualifies, confirm the original identity remains active. If one qualifies, confirm transactional activation, new IP, and all four results.

- [ ] **Step 6: Final verification and cleanup**

Run full config validation, confirm sing-box/Argo/HTTPS subscription/Nginx expected states, probe direct and WARP egress, verify current routes, check mode 700/600 credentials, and ensure no temporary proxy process, listener, candidate directory, or uploaded deployment file remains. Keep one successful rollback backup and remove only confirmed redundant process artifacts.
