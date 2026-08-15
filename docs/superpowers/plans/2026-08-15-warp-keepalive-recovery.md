# WARP Keepalive Recovery Implementation Plan

> **For Codex:** Execute this plan test-first and verify both the public script and the live VPS before publishing.

**Goal:** Prevent the built-in sing-box WARP endpoint from becoming unreachable because multiple installations share one public WireGuard identity, while also keeping the UDP path alive on NAT hosts.

**Architecture:** Keep WARP inside sing-box and preserve selective routing. On first use, generate a local X25519 keypair with sing-box, register it directly with Cloudflare's client API, convert `client_id` into the required three reserved bytes, and save the account/endpoint state with mode `600`. Reuse a valid unique endpoint, migrate the legacy shared endpoint automatically, add WireGuard persistent keepalive, and deploy the same identity model transactionally to the current VPS.

**Tech Stack:** Bash, jq, sing-box WireGuard endpoint, systemd, Git/GitHub.

---

### Task 1: Lock the regression with a failing test

**Files:**
- Modify: `tests/test_warp_routing.sh`

1. Assert that `warp_endpoint_json` emits a unique WireGuard peer with three reserved bytes and `persistent_keepalive_interval` set to a safe positive interval.
2. Assert that the legacy shared identity is absent from the script and is replaced from persisted unique state.
3. Run `bash tests/test_warp_routing.sh` on a Linux host with `jq`.
4. Confirm the assertion fails against the current implementation.

### Task 2: Generate and persist a unique WARP identity

**Files:**
- Modify: `sing-box.sh`
- Modify: `README.md`
- Test: `tests/test_warp_routing.sh`

1. Add helpers that detect the legacy shared endpoint and validate an existing unique endpoint.
2. Register a per-install identity directly with Cloudflare using a locally generated keypair; persist account and endpoint files securely.
3. Add `persistent_keepalive_interval: 25` to the generated peer.
4. Document the one-time registration, secure local state, migration, and direct fallback behavior.
5. Run the WARP regression test and shell syntax validation.

### Task 3: Repair and verify the current VPS

**Files:**
- Modify: `/etc/sing-box/conf/endpoints.json` on the VPS

1. Back up the active endpoint and route files to `/etc/sing-box/backups/`.
2. Generate and probe a unique identity, validate the full config, then atomically replace the endpoint file.
3. Restart sing-box once.
4. Verify service health, direct egress, WARP egress, and selected-vs-unselected routing.

### Task 4: Publish the public fix

**Files:**
- Commit: `sing-box.sh`, `tests/test_warp_routing.sh`, `README.md`, and this plan.

1. Run `git diff --check`, WARP tests, shell syntax validation, and relevant regression tests.
2. Review the diff for secrets and unrelated files.
3. Commit the focused change and push it to GitHub without including unrelated worktree changes.
