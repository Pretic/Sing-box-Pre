# WARP IP Rotation and Multi-Service Unlock Design

## Goal

Add safe, user-visible management for the sing-box built-in WARP identity. Users can inspect the current WARP state, rotate the identity once, or automatically search for a different WARP egress IP that unlocks selected services. The feature must not install a host WARP interface, Cloudflare Linux Client, WireProxy, a daemon, cron job, or a permanent local proxy.

This iteration changes the local public-script working tree and the currently connected VPS only. It does not create a Git commit or push GitHub.

## Menu and user flow

The main menu status block adds a WARP line between Argo and Nginx:

```text
---Argo 状态: running
---WARP 状态: running
---Nginx 状态: running
singbox 状态: running
```

The status is not based on a host WireGuard interface, `warp-cli`, or WireProxy. `running` means the sing-box built-in `wireguard-out` endpoint is initialized, structurally valid, and its cached/recent runtime probe succeeded. An uninitialized endpoint shows `not configured`; an endpoint that exists but fails a runtime probe shows `degraded`. The main menu uses a short-lived cached result so opening or redrawing the menu does not repeatedly run network probes or slow interactive use.

The existing `WARP分流管理` menu retains its four routing/proxy operations and adds:

```text
5. 查看内置 WARP 状态及解锁情况
6. 更换内置 WARP 身份/IP
7. 自动优选 WARP IP（多平台解锁）
```

Status output is sanitized. It may show device ID, account type, internal addresses, peer endpoint, keepalive, egress IP, Cloudflare colo, WARP state, and unlock results. It must never print the account token, private key, client ID, or reserved bytes.

Single rotation registers one new free WARP device identity, probes it in isolation, and shows whether its public egress IP differs from the current one. A successful, working identity may be applied even when Cloudflare assigns the same public IP, but the menu must clearly state that the IP did not change.

Automatic selection lets the user choose any combination of Netflix, Disney+, ChatGPT, and Gemini. The default is all four. A candidate is accepted only when:

1. its Cloudflare trace reports WARP enabled;
2. its public egress IP differs from the active WARP egress IP; and
3. every selected unlock test passes.

The selector tries at most five identities with increasing waits between attempts. It does not run indefinitely. If none passes, the active identity and running sing-box configuration remain unchanged.

## Candidate isolation and activation

Each candidate is generated under a mode-0700 temporary directory inside the WARP state directory. Account and endpoint files remain mode 0600. The script starts a temporary sing-box instance bound only to a dynamically selected `127.0.0.1` mixed/SOCKS port. The temporary instance contains the candidate WireGuard endpoint and routes all probe requests through that endpoint.

Probes never replace the live endpoint, restart the production sing-box service, or alter routing rules. Candidate processes and files are removed after each attempt.

After a candidate passes, activation is transactional:

1. back up the active account, persisted endpoint, and live `endpoints.json`;
2. install the candidate account and endpoint with restrictive permissions;
3. replace only the `wireguard-out` object in `endpoints.json`;
4. validate the complete sing-box configuration;
5. restart sing-box and confirm the service is active;
6. re-probe the committed WARP endpoint;
7. restore the previous files and restart the old configuration if any step fails.

The existing route rules are not regenerated or changed during identity rotation. Traffic not assigned to `wireguard-out` continues using the native VPS address.

## Unlock detection

All requests use short connection and total timeouts and run through the candidate-only local proxy.

- Cloudflare trace: obtains public IP, colo, location, and `warp=on|plus`; this is the authoritative tunnel health and IP-change check.
- Netflix: tests two public title pages and distinguishes full catalogue from originals-only while extracting the region where possible.
- Disney+: uses the public browser device/session flow and requires a supported location result.
- ChatGPT: checks ChatGPT web reachability and OpenAI's iOS restriction response; web-only availability is reported separately and does not count as a full pass by default.
- Gemini: checks Gemini web reachability and rejects responses or redirects that indicate the service is unavailable for the candidate region. Because Gemini can also require account login, the result is explicitly labelled as network/region availability rather than account-level usability.

Network errors and detector ambiguity are reported as `检测失败`, not as unlocked. A status-only check runs all four detectors but never changes the WARP identity.

## Registration hygiene and limits

Candidate generation reuses the existing per-VPS local key generation and Cloudflare free-device registration code. The current active identity is never deleted before a replacement is committed.

Rejected candidates are deleted through the Cloudflare device-registration API when their device ID and token are available. Cleanup failure is non-fatal but is reported. Local candidate credentials are always removed. Registration retries inside one candidate remain limited, and the outer selector is capped at five candidates to avoid API abuse and unbounded account creation.

No attempt is made to select an exact country or ASN. Cloudflare Anycast and the VPS route determine the available colo and exit pool, so a new identity cannot guarantee a new country or even a new public IP.

## Compatibility and resource use

- NAT VPS: needs only outbound TCP for registration/tests and outbound UDP to the WARP peer; no inbound mapping is added.
- IPv4-only, IPv6-only, and dual-stack hosts: candidate proxy and peer resolution follow the existing sing-box endpoint behavior. Failure to reach the peer leaves the active identity untouched.
- Runtime cost: only one temporary sing-box process and sequential curl probes per candidate; no background service remains.
- Existing custom outbounds, endpoints, subscription files, Argo tunnel, HTTPS subscription, and WARP routing rules are preserved.

## Verification

Automated shell tests cover:

- sanitized status output and secret non-disclosure;
- main-menu `running`, `not configured`, and `degraded` display with probe caching;
- candidate selection criteria and five-attempt limit;
- same-IP rejection in automatic mode;
- multi-select unlock aggregation including Gemini;
- candidate cleanup and failed-registration handling;
- successful transactional activation;
- config-validation, restart, and post-activation probe rollback;
- preservation of unrelated endpoints and routing configuration;
- absence of a system WARP interface, daemon, or new inbound listener after completion.

The current VPS verification records native egress, old WARP egress, selected candidate result, final WARP egress, service status, configuration check, active route rules, file permissions, and leftover temporary processes/files.
