# WARP Routing Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the public sing-box WARP menu self-healing, transactional, NAT-compatible, and accurately testable without changing the host default route.

**Architecture:** Keep all routing inside the existing `sing-box.sh`. Add canonical JSON emitters and transactional helpers, then route each menu action through those helpers. Use a focused Bash regression test that extracts and executes the WARP function block against temporary configuration fixtures.

**Tech Stack:** Bash, jq, sing-box configuration JSON, systemd/OpenRC, GitHub.

---

### Task 1: Add failing WARP regression tests

**Files:**
- Create: `tests/test_warp_routing.sh`
- Test: `tests/test_warp_routing.sh`

- [ ] **Step 1: Write a fixture-driven test for missing prerequisite files**

Create temporary `conf` files, source the WARP function block with mocked service functions, call `ensure_warp_prerequisites`, and assert that `direct`, `wireguard-out`, required rule sets, and unrelated custom entries coexist.

- [ ] **Step 2: Write routing behavior assertions**

Assert that WARP additions insert sniff first, add native-IPv6 direct fallback only when requested, avoid duplicate service tags, and remove the selected tag cleanly.

- [ ] **Step 3: Write transactional failure assertions**

Force configuration validation and restart failures, then assert that the original route content is restored byte-for-byte.

- [ ] **Step 4: Run the new test and verify RED**

Run: `bash tests/test_warp_routing.sh`

Expected: FAIL because the new WARP helpers are not implemented.

### Task 2: Implement prerequisite repair

**Files:**
- Modify: `sing-box.sh` near the WARP management functions
- Test: `tests/test_warp_routing.sh`

- [ ] **Step 1: Add canonical WARP endpoint and rule-set JSON emitters**

Reuse the project's existing endpoint profile and rule-set URLs, adding the `streaming` aggregate rule set.

- [ ] **Step 2: Add `ensure_warp_prerequisites`**

Repair `outbounds.json`, `endpoints.json`, and `route.json` in one transaction, preserve unrelated objects, validate the complete configuration, and restore every prior file on failure.

- [ ] **Step 3: Run the focused test**

Run: `bash tests/test_warp_routing.sh`

Expected: prerequisite cases pass; routing cases remain failing.

### Task 3: Implement transactional route mutations

**Files:**
- Modify: `sing-box.sh` WARP management functions
- Test: `tests/test_warp_routing.sh`

- [ ] **Step 1: Add a checked sing-box restart helper**

Return the actual OpenRC/systemd result so callers can distinguish success from the existing colored status output.

- [ ] **Step 2: Add the route transaction helper**

Generate a candidate route with jq, validate it, restart sing-box, and restore the backup plus previous running configuration if validation or restart fails.

- [ ] **Step 3: Add service-rule add/delete helpers**

Preserve unrelated rules, insert sniff, implement conditional native-IPv6 direct bypass, and avoid duplicate service tags.

- [ ] **Step 4: Run the focused test**

Run: `bash tests/test_warp_routing.sh`

Expected: all focused cases pass.

### Task 4: Wire the menu to safe helpers

**Files:**
- Modify: `sing-box.sh` WARP menu, global mode, restore mode, and install defaults
- Test: `tests/test_warp_routing.sh`

- [ ] **Step 1: Display endpoint readiness and add common streaming**

Keep the existing menu structure while accurately reporting whether `wireguard-out` is ready.

- [ ] **Step 2: Replace raw route writes**

Use the transactional helpers for add, delete, global proxy, and restore operations, and report failure instead of unconditional success.

- [ ] **Step 3: Remove destructive global proxy behavior**

Set `route.final` explicitly and retain `route.json`, `endpoints.json`, and `direct`.

- [ ] **Step 4: Run focused and existing tests**

Run: `for test_file in tests/test_*.sh; do bash "$test_file"; done`

Expected: every test passes.

### Task 5: Validate on the VPS and publish

**Files:**
- Modify on VPS only if required: `/usr/local/lib/sing-box-pre/sing-box.sh`
- Validate: `/etc/sing-box/conf/*.json`

- [ ] **Step 1: Back up and deploy only the generic WARP function changes if the VPS script is behind**

Preserve the current working route and endpoint configuration. Do not overwrite VPS-specific subscription or Cloudflare settings.

- [ ] **Step 2: Validate configuration and service**

Run the actual `/etc/sing-box/sing-box check -C /etc/sing-box/conf`, confirm `sing-box` is active, and inspect the effective route rules.

- [ ] **Step 3: Probe direct and WARP egress**

Confirm the direct IPv4/IPv6 addresses, WARP IPv4 address, expected WARP IPv6 result, and that unmatched traffic remains direct.

- [ ] **Step 4: Review and commit only intended files**

Run `git diff --check`, inspect `git diff`, stage `sing-box.sh`, `tests/test_warp_routing.sh`, and the two documentation files explicitly, then commit with a focused message.

- [ ] **Step 5: Push the verified branch to GitHub**

Push `agent/fix-warp-routing` with tracking, then integrate into the requested public branch only after confirming the remote branch state has not moved.
