# Bounded WARP Rotation and Streaming Rule Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make menu option 6 continue through bounded five-candidate WARP batches until the exit IPv4 changes, and replace the incomplete streaming rule source with the verified full entertainment ruleset.

**Architecture:** Keep `rotate_warp_identity_once` as the existing five-candidate transactional unit and add a small outer controller that handles validated limits and return codes. Keep the existing `streaming` tag and route shape, changing only its remote rule-set URL so all existing menu and deletion logic remains compatible.

**Tech Stack:** Bash, jq, curl, sing-box CLI, existing shell regression tests, Debian staging VPS.

---

## File structure

- Modify `sing-box.sh`: add the bounded rotation controller, dispatch option 6 through it, and replace both streaming rule source declarations.
- Create `tests/test_warp_continuous_rotation.sh`: behavior tests for retry, success, unsafe stop, batch limit, time limit, and input clamping.
- Modify `tests/test_warp_menu_dispatch.sh`: assert the dispatcher calls the bounded controller and preserves return-code messages.
- Modify `tests/test_warp_routing.sh`: assert initial and repaired route configurations use the verified entertainment rule source.
- Keep `docs/superpowers/specs/2026-08-27-warp-bounded-rotation-streaming-design.md` as the approved behavior contract.

### Task 1: Add failing bounded-rotation tests

**Files:**
- Create: `tests/test_warp_continuous_rotation.sh`
- Modify: `tests/test_warp_menu_dispatch.sh`

- [ ] **Step 1: Write the controller behavior test**

Extract `rotate_warp_identity_until_new` from `sing-box.sh`, replace `rotate_warp_identity_once`, `warp_rotation_now`, and `sleep` with deterministic test doubles, and assert these call sequences:

```bash
ROTATE_RESULTS='1 1 0'
WARP_ROTATION_MAX_BATCHES=4
WARP_ROTATION_MAX_SECONDS=600
rotate_warp_identity_until_new
[[ "$ROTATE_CALLS" -eq 3 ]]

ROTATE_RESULTS='2 0'
if rotate_warp_identity_until_new; then rc=0; else rc=$?; fi
[[ "$rc" -eq 2 && "$ROTATE_CALLS" -eq 1 ]]

ROTATE_RESULTS='1 1 1 1 0'
WARP_ROTATION_MAX_BATCHES=4
if rotate_warp_identity_until_new; then rc=0; else rc=$?; fi
[[ "$rc" -eq 1 && "$ROTATE_CALLS" -eq 4 ]]
```

Also return timestamps `0 601` from `warp_rotation_now` and assert a successful-looking second batch is never started after the 600-second budget expires. Supply invalid and excessive environment values and assert the production defaults/clamps prevent an unbounded loop.

- [ ] **Step 2: Update the dispatcher test**

Stub `rotate_warp_identity_until_new` instead of `rotate_warp_identity_once`, preserve the current assertions for return codes `0`, `1`, and `2`, and assert menu option 6 still calls `dispatch_warp_rotation_menu_action`.

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
bash tests/test_warp_continuous_rotation.sh
bash tests/test_warp_menu_dispatch.sh
```

Expected: the first test fails because `rotate_warp_identity_until_new` is absent, and the dispatcher test fails because it still calls the one-batch function.

### Task 2: Implement the bounded rotation controller

**Files:**
- Modify: `sing-box.sh` after `rotate_warp_identity_once`
- Test: `tests/test_warp_continuous_rotation.sh`
- Test: `tests/test_warp_menu_dispatch.sh`

- [ ] **Step 1: Add the clock helper and controller**

Implement:

```bash
warp_rotation_now() {
    date +%s
}

rotate_warp_identity_until_new() {
    local max_batches="${WARP_ROTATION_MAX_BATCHES:-4}"
    local max_seconds="${WARP_ROTATION_MAX_SECONDS:-600}"
    local started_at now batch rotate_rc elapsed

    case "$max_batches" in ''|*[!0-9]*) max_batches=4 ;; esac
    case "$max_seconds" in ''|*[!0-9]*) max_seconds=600 ;; esac
    [ "$max_batches" -lt 1 ] && max_batches=1
    [ "$max_batches" -gt 12 ] && max_batches=12
    [ "$max_seconds" -lt 60 ] && max_seconds=60
    [ "$max_seconds" -gt 3600 ] && max_seconds=3600

    started_at=$(warp_rotation_now) || return 1
    for ((batch=1; batch<=max_batches; batch++)); do
        if [ "$batch" -gt 1 ]; then
            now=$(warp_rotation_now) || return 1
            elapsed=$((now - started_at))
            if [ "$elapsed" -ge "$max_seconds" ]; then
                red "WARP 身份更换达到 ${max_seconds} 秒时间上限，未获得不同出口。"
                return 1
            fi
        fi
        yellow "正在执行 WARP 更换批次 ${batch}/${max_batches}（每批最多 5 个候选）..."
        if rotate_warp_identity_once; then
            return 0
        else
            rotate_rc=$?
        fi
        case "$rotate_rc" in
            1) ;;
            2) return 2 ;;
            *) return "$rotate_rc" ;;
        esac
        [ "$batch" -lt "$max_batches" ] && sleep 10
    done
    red "WARP 身份更换已达到 ${max_batches} 批上限，未获得不同出口。"
    return 1
}
```

The controller prints `批次 N/M` before each transaction. After safe exhaustion it prints whether the batch limit or time limit stopped the operation and returns `1`; it never claims the active configuration is unchanged for return code `2`.

- [ ] **Step 2: Route the existing dispatcher through the controller**

Change only this call:

```bash
if rotate_warp_identity_until_new; then
```

Keep all existing final status text and return-code handling.

- [ ] **Step 3: Run the focused tests and verify GREEN**

Run:

```bash
bash tests/test_warp_continuous_rotation.sh
bash tests/test_warp_menu_dispatch.sh
bash tests/test_warp_rotation.sh
bash tests/test_warp_rotation_behavior.sh
```

Expected: all four exit `0`; the original five-candidate transaction tests remain unchanged.

- [ ] **Step 4: Commit the controller and tests**

```bash
git add sing-box.sh tests/test_warp_continuous_rotation.sh tests/test_warp_menu_dispatch.sh
git commit -m "fix: retry WARP rotation within safe bounds"
```

### Task 3: Add a failing streaming rule regression

**Files:**
- Modify: `tests/test_warp_routing.sh`

- [ ] **Step 1: Assert the exact verified source**

After `ensure_warp_prerequisites`, assert:

```bash
streaming_url='https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-entertainment.srs'
jq -e --arg url "$streaming_url" \
  '.route.rule_set | any(.tag == "streaming" and .url == $url)' \
  "$route_file" >/dev/null
! grep -Fq 'geo-lite/geosite/proxymedia.srs' "$script"
[[ "$(grep -Fc "$streaming_url" "$script")" -eq 2 ]]
```

The count of two covers both the initial installation template and the repair helper.

- [ ] **Step 2: Run the routing test and verify RED**

Run:

```bash
bash tests/test_warp_routing.sh
```

Expected: failure because the current script still contains `proxymedia.srs`.

### Task 4: Replace the streaming source and run regressions

**Files:**
- Modify: `sing-box.sh` at both `streaming` rule-set declarations
- Test: `tests/test_warp_routing.sh`

- [ ] **Step 1: Make the minimal source replacement**

Replace only:

```text
https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/proxymedia.srs
```

with:

```text
https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-entertainment.srs
```

- [ ] **Step 2: Run the routing test and verify GREEN**

Run:

```bash
bash tests/test_warp_routing.sh
```

Expected: `WARP routing tests passed.`

- [ ] **Step 3: Run syntax, static, and full shell tests**

Run:

```bash
bash -n sing-box.sh
shellcheck sing-box.sh
for test_file in tests/*.sh; do bash "$test_file"; done
git diff --check
```

Expected: syntax and diff checks exit `0`; ShellCheck has no new findings attributable to this patch; every existing shell test passes.

- [ ] **Step 4: Commit the streaming repair**

```bash
git add sing-box.sh tests/test_warp_routing.sh
git commit -m "fix: cover common streaming services in WARP routing"
```

### Task 5: Deploy and verify the disposable staging VPS

**Files:**
- Deploy: local `sing-box.sh` to `/usr/local/lib/sing-box-pre/sing-box.sh`
- Preserve: `/etc/sing-box/conf`, WARP credentials, subscriptions, Argo, Nginx, and service state

- [ ] **Step 1: Capture hashes and create a recoverable script backup**

Record the installed script hash, route configuration hash, service states, and current WARP cache/live consistency without printing any IP. Create a timestamped mode-0700 backup directory under `/etc/sing-box/backups/` and copy only the installed manager script into it.

- [ ] **Step 2: Install and validate the manager script**

Transfer through the existing authenticated SSH session into a temporary file, verify its local and remote SHA-256 values match, run `bash -n`, then atomically install it mode `0700`. Deployment alone must not change live configuration hashes or restart services.

- [ ] **Step 3: Refresh the existing streaming rule safely**

Invoke the existing prerequisite/route repair path so only the `streaming` remote URL changes. Run full sing-box configuration validation and restart only if the existing transactional function requires it. Confirm all selected route tags and `route.final = direct` remain intact.

- [ ] **Step 4: Prove real split routing**

Start a temporary localhost-only sing-box instance from the active WARP endpoint and current route data. Send real HTTPS requests for Disney+, Hulu, Max, Prime Video, Spotify, Netflix, and YouTube and assert debug logs select `wireguard-out`. Send `example.com` as a control and assert it selects `direct`. Stop the temporary process and remove its directory.

- [ ] **Step 5: Final safety verification**

Confirm sing-box configuration validity, sing-box and Argo service health, WARP probe health/cache consistency, unchanged subscription and endpoint files, no candidate directories or temporary listeners, and no access to the production DMIT VPS. Do not run a second live IP rotation merely to test the wrapper; automated tests cover it without consuming registrations.

### Task 6: Report without pushing

**Files:**
- Inspect: Git status and commit history only

- [ ] **Step 1: Report outcomes and remaining state**

List the exact modified files, RED/GREEN tests, full regression totals, staging traffic-routing matrix, service health, local commits, and the six pre-existing unrelated modified files. State explicitly that GitHub was not pushed and production DMIT was not changed.
