# Stable Transaction Root Batch 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Sing-box-Pre and Pre-cfy one durable, shared lock namespace with strict lock ordering, legacy-lock bridging, and a race-safe managed-service writer without changing proxy data paths.

**Architecture:** Both standalone Bash scripts implement the same versioned filesystem contract under `${SING_BOX_TRANSACTION_ROOT:-/var/lib/sing-box-transactions}`. Upgraded processes serialize on permanent `flock` files in the order `mutation -> subscription -> firewall`; while a safe legacy lock file already exists, they also hold it so an older installed process cannot overlap. This batch creates only the common root and lock layer plus service-writer CAS protection; persistent operation manifests and automatic crash recovery are separate follow-on batches.

**Tech Stack:** Bash, util-linux `flock`, GNU `stat`/`sha256sum`, coreutils, offline shell tests.

---

## File map

- Modify `sing-box.sh`: shared root helpers, ordered lock helpers, legacy bridge, existing proxy/subscription/firewall wrapper integration, and managed-service digest CAS.
- Create `tests/test_stable_transaction_root.sh`: Sing-box root layout, permissions, inode stability, order, nesting, contention, corruption, and legacy bridge tests.
- Modify `tests/test_managed_service_writers.sh`: external replacement race and mutation-lock coverage.
- Modify relevant existing transaction tests only where their mocks must expose the new shared helpers; do not weaken existing assertions.
- Modify the sibling Pre-cfy repository's `cfy.sh`: identical root contract for the subscription lock and safe legacy bridge.
- Create the sibling Pre-cfy repository's `tests/test_stable_transaction_root.sh`: the same public filesystem contract plus cross-process contention with the Sing-box implementation when `SING_BOX_SCRIPT` is supplied.
- Modify both READMEs after implementation: root path override, permissions, lock order, compatibility boundary, and no data-plane overhead.

### Task 1: Specify the versioned transaction-root contract in Sing-box

**Files:**
- Create: `tests/test_stable_transaction_root.sh`
- Modify: `sing-box.sh` near constants and `command_exists`

- [x] **Step 1: Write failing root-layout tests**

Extract the new helpers by name from `sing-box.sh`, set `SING_BOX_TRANSACTION_ROOT` to a private temporary directory, and assert:

```bash
ensure_stable_transaction_root
test "$(cat "$SING_BOX_TRANSACTION_ROOT/schema-version")" = 1
test "$(stat -c '%a' "$SING_BOX_TRANSACTION_ROOT")" = 700
test "$(stat -c '%a' "$SING_BOX_TRANSACTION_ROOT/pending")" = 700
test "$(stat -c '%a' "$SING_BOX_TRANSACTION_ROOT/recoveries")" = 700
for kind in mutation subscription firewall; do
    path="$SING_BOX_TRANSACTION_ROOT/${kind}.lock"
    test -f "$path" && test ! -L "$path"
    test "$(stat -c '%a' "$path")" = 600
    test "$(stat -c '%h' "$path")" = 1
done
```

Also assert fail-closed behavior for a symlink root, symlink/hard-linked schema or lock, foreign schema value, non-private owned modes that cannot be repaired, relative override, and unknown lock kind. Record every lock inode before and after repeated initialization and require it to remain unchanged.

- [x] **Step 2: Run the test and verify RED**

Run:

```bash
bash tests/test_stable_transaction_root.sh
```

Expected: FAIL because `ensure_stable_transaction_root` and the ordered lock helpers do not exist.

- [x] **Step 3: Implement the strict root initializer**

Add these interfaces to `sing-box.sh`:

```bash
transaction_root_path()                 # print one validated absolute path
transaction_expected_dir_mode()         # 700, or 750 with trusted group
transaction_expected_file_mode()        # 600, or 640 with trusted group
transaction_expected_gid()              # current gid, or validated group gid
validate_transaction_directory PATH MODE GID
ensure_transaction_directory PATH MODE GID
validate_transaction_regular_file PATH MODE GID
ensure_transaction_regular_file PATH MODE GID
ensure_stable_transaction_root
stable_transaction_lock_path KIND       # mutation|subscription|firewall only
```

`ensure_stable_transaction_root` must create/validate exactly:

```text
${SING_BOX_TRANSACTION_ROOT:-/var/lib/sing-box-transactions}/
  schema-version       # one line: 1, mode 0600
  mutation.lock        # permanent, mode 0600
  subscription.lock    # permanent, mode 0600
  firewall.lock        # permanent, mode 0600
  pending/             # mode 0700
  recoveries/          # mode 0700
```

When `SING_BOX_TRANSACTION_GROUP` is non-empty, resolve it with `getent group` or a numeric gid, use directory mode `0750`, file mode `0640`, and reject an unresolved group. Every existing object must be owned by the effective uid, have the expected gid/mode after safe repair, be the expected type, and not be a symlink; regular files must have link count one. Create `schema-version` through a same-directory temporary file and a no-replace hard link so an existing path is never overwritten. Create lock files only with append/open semantics; never truncate, rename, or delete them.

- [x] **Step 4: Run focused tests and static checks**

Run:

```bash
bash tests/test_stable_transaction_root.sh
bash -n sing-box.sh tests/test_stable_transaction_root.sh
shellcheck -S error sing-box.sh tests/test_stable_transaction_root.sh
```

Expected: PASS.

### Task 2: Add ordered, re-entrant stable locks and safe legacy bridging

**Files:**
- Modify: `sing-box.sh` lock helper area
- Modify: `tests/test_stable_transaction_root.sh`
- Modify: `tests/test_durable_transactions.sh`
- Modify: `tests/test_subscription_contract.sh`
- Modify: `tests/test_firewall_ownership.sh`

- [x] **Step 1: Add failing order, contention, and bridge tests**

Cover these behaviors with real `flock` processes:

```text
mutation -> subscription -> firewall succeeds
subscription -> mutation returns 2 without leaking either fd
firewall -> subscription returns 2 without leaking either fd
nested acquisition of the same kind increments depth and unlocks only at depth zero
a second process times out on the same stable lock
release never changes lock inode or contents
an existing safe legacy lock is held after the stable lock
an absent legacy lock is not created
a symlink, directory, hard link, foreign owner, or unsafe legacy lock returns 2
```

Use test-only hook functions immediately after stable acquisition and after legacy acquisition so tests can prove the order without sleeps.

- [x] **Step 2: Run and verify RED**

Run:

```bash
bash tests/test_stable_transaction_root.sh
```

Expected: FAIL at the first ordered-lock assertion.

- [x] **Step 3: Implement the lock API**

Add these interfaces:

```bash
stable_transaction_lock_rank KIND
stable_transaction_lock_is_held KIND
acquire_stable_transaction_lock KIND [TIMEOUT]
release_stable_transaction_lock KIND
with_stable_transaction_lock KIND CALLBACK [ARGS...]
acquire_safe_legacy_lock KIND PATH [TIMEOUT]
release_safe_legacy_lock KIND
```

Use one permanent fd and one depth counter per kind. Reject acquiring rank 1 while rank 2/3 is held, or rank 2 while rank 3 is held, with rc=2. A repeated same-kind acquisition is re-entrant. Use `flock -x -w`; rc=1 means bounded contention, rc=2 means unsafe/corrupt/order violation. Release in reverse order and keep permanent files untouched.

The bridge rules are:

```text
1. acquire stable lock
2. if the configured legacy path exists, validate and flock it
3. perform the operation
4. release legacy lock
5. release stable lock
```

Never create a missing legacy file in this compatibility layer. Existing legacy files must be current-euid owned, regular, non-symlink, link-count one, and mode 0600 or the trusted-group mode.

- [x] **Step 4: Rewire existing wrappers without changing callers**

Keep public function names and rc semantics:

```text
acquire_proxy_transaction_lock -> stable mutation + safe existing legacy proxy lock
with_subscription_lock          -> stable subscription + safe existing legacy subscription lock
acquire_firewall_lock           -> stable firewall + safe existing legacy firewall lock
```

Keep `assert_no_pending_durable_transaction` after both mutation locks are held. Preserve nested `SUBSCRIPTION_LOCK_HELD`, firewall state behavior, NAT behavior, and IPv4/IPv6 independence. The old mkdir reaper helpers may remain readable for recovery compatibility, but normal upgraded acquisition must use the stable `flock` contract.

- [x] **Step 5: Run focused and existing regression tests**

Run:

```bash
bash tests/test_stable_transaction_root.sh
bash tests/test_durable_transactions.sh
bash tests/test_subscription_contract.sh
bash tests/test_firewall_ownership.sh
bash tests/test_hy2_transactions.sh
```

Expected: PASS, including rc 0/1/2 assertions.

### Task 3: Close the managed-service writer TOCTOU

**Files:**
- Modify: `sing-box.sh` `write_guarded_managed_service_definition`
- Modify: `tests/test_managed_service_writers.sh`

- [ ] **Step 1: Add a failing external-replacement race test**

Create a canonical target, call the writer, and use `managed_service_writer_hook before-final-cas TARGET` to replace it with foreign content after initial validation. Assert rc=2, exact foreign bytes preserved, no temporary file remains, and the stable mutation lock was held during the hook. Repeat for an initially absent target that appears before commit.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
bash tests/test_managed_service_writers.sh
```

Expected: FAIL because the current writer overwrites the replacement.

- [ ] **Step 3: Implement digest/inode CAS under the mutation lock**

Add:

```bash
managed_service_target_fingerprint TARGET
write_guarded_managed_service_definition_locked TARGET MODE KIND RENDERER [ARGS...]
```

Fingerprint an existing target as `present:<device>:<inode>:<size>:<sha256>` and absence as `absent`. Under `with_stable_transaction_lock mutation`, capture the initial fingerprint only after canonical validation, render and validate the temporary definition, invoke the test hook, recalculate immediately before `mv`, and return rc=2 if the fingerprint changed. On every failure remove only the writer-owned temporary file. The outer public writer keeps the existing function name and propagates rc 0/1/2.

- [ ] **Step 4: Run writer and lifecycle regressions**

Run:

```bash
bash tests/test_managed_service_writers.sh
bash tests/test_partial_install_reentry.sh
bash tests/test_lifecycle_safety.sh
```

Expected: PASS.

### Task 4: Implement the same subscription lock contract in Pre-cfy

**Files (sibling Pre-cfy repository):**
- Modify: `cfy.sh`
- Create: `tests/test_stable_transaction_root.sh`
- Modify: `tests/test_subscription_contract.sh`
- Modify: `tests/test_update_dependency_preflight.sh`

- [ ] **Step 1: Write failing Pre-cfy contract tests**

Assert the same root path, schema version, modes, permanent `subscription.lock`, corruption rejection, rc meanings, stable-then-legacy order, nesting, timeout, and absent-legacy behavior. When `SING_BOX_SCRIPT` points to the Sing-box worktree, hold Sing-box's subscription lock in one process and assert cfy times out, then reverse the roles.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
bash tests/test_stable_transaction_root.sh
```

Expected: FAIL because cfy still uses only `/etc/sing-box/.subscription.lock`.

- [ ] **Step 3: Port the identical root and subscription-lock primitives**

Keep cfy standalone: duplicate the small, versioned filesystem protocol rather than sourcing a runtime library. `with_subscription_lock` must acquire stable subscription first, then the safe existing `${SUBSCRIPTION_LOCK_FILE:-/etc/sing-box/.subscription.lock}`, and release in reverse. Keep `flock` and `sha256sum` in update preflight; add `stat`, `getent` only when the selected trusted-group mode requires them.

- [ ] **Step 4: Run all cfy tests and static checks**

Run:

```bash
for test_file in tests/test_*.sh; do bash "$test_file" || exit 1; done
bash -n cfy.sh tests/test_*.sh
shellcheck -S error cfy.sh tests/test_*.sh
```

Expected: all tests PASS.

### Task 5: Document, verify, and commit Batch 1

**Files:**
- Modify: `README.md` in each repository
- Modify: this plan's checkboxes as tasks complete

- [ ] **Step 1: Document the public compatibility contract**

Document:

```text
default root /var/lib/sing-box-transactions
SING_BOX_TRANSACTION_ROOT test/chroot override
optional SING_BOX_TRANSACTION_GROUP trusted group
lock order mutation -> subscription -> firewall
permanent lock files are never deleted or truncated
safe existing legacy locks are bridged during upgrades
unsafe objects fail closed
locks affect only control-plane changes, not proxy packet flow or throughput
```

- [ ] **Step 2: Run full offline gates in both repositories**

Run all shell tests, every `.sh` through `bash -n`, ShellCheck at error severity, and `git diff --check`. Confirm Sing-box still has only the six known EOL-only unstaged files outside the scoped commit.

- [ ] **Step 3: Review scope and protocol equality**

Compare the shared constants and subscription lock behavior in both scripts. Confirm no code reads or changes Windows network settings, no network calls are needed for tests, no data-plane service config changes, and no VPS/GitHub action occurred.

- [ ] **Step 4: Commit independently**

In Sing-box:

```bash
git add sing-box.sh tests/test_stable_transaction_root.sh tests/test_managed_service_writers.sh README.md docs/superpowers/plans/2026-08-26-stable-transaction-root.md
git commit -m "fix: establish stable transaction locks"
```

Add only other test fixture files actually changed for the lock integration; never stage the six EOL-only noise files.

In Pre-cfy:

```bash
git add cfy.sh tests/test_stable_transaction_root.sh tests/test_subscription_contract.sh tests/test_update_dependency_preflight.sh README.md
git commit -m "fix: share stable subscription lock"
```

Do not push. Persistent manifests, operation recovery, WARP remote-uncertain handling, and cleanup migration belong to later plans.
