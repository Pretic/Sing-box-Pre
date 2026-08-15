# WARP Routing Reliability Design

## Goal

Make the public WARP routing menu reliable on fresh, upgraded, partially configured, dual-stack, single-stack, and NAT VPS installations without changing the host's default network route.

## Selected approach

Keep WARP as a sing-box built-in WireGuard endpoint. Do not install a system WARP client or create a host WireGuard interface. All WARP traffic selection remains inside sing-box, so traffic that does not match a selected service continues to use the server's normal `direct` outbound.

Before a WARP rule is enabled, the script repairs the minimum required state:

- ensure `outbounds.json` contains the `direct` outbound while preserving user proxy outbounds;
- ensure `endpoints.json` contains a valid `wireguard-out` endpoint while preserving unrelated endpoints;
- ensure `route.json` contains every supported remote rule set while preserving unrelated rule sets and route rules;
- add a port 80/443 sniff action so domain rule sets can still match clients that send an IP destination;
- validate the complete sing-box configuration before accepting the repaired state.

## Routing behavior

The menu continues to offer individual OpenAI, Claude, Gemini, Google, TikTok, Twitter, YouTube, Netflix, and Telegram rules, and adds a common-streaming aggregate rule.

When no Socks5/HTTP outbound exists, the selected service uses `wireguard-out`. On a VPS with working native IPv6, an earlier IPv6-only `direct` rule is added for that service because the bundled WARP profile is not reliably carrying IPv6 on every host. IPv4 traffic still uses WARP. On a host without working native IPv6, no direct IPv6 bypass is added, allowing the tunnel to provide the only possible IPv6 path.

When a user selects a Socks5/HTTP outbound, the same service rule is routed to that outbound and no WARP-specific IPv6 bypass is added.

Global proxy mode no longer deletes `route.json`, `endpoints.json`, or the `direct` outbound. It explicitly sets `route.final` to the chosen proxy. Restore mode explicitly sets `route.final` to `direct` and retains custom proxy and endpoint definitions.

## Safety and recovery

Every route mutation is transactional:

1. create a same-directory temporary file and backup;
2. generate and parse the candidate JSON;
3. run the installed sing-box binary's full configuration check;
4. restart sing-box and verify the service operation returned success;
5. restore the previous file and restart the previous configuration if either validation or restart fails.

Repairing multiple prerequisite files uses one backup directory and restores all changed files together if validation fails. Private endpoint material remains mode `0600`.

## Compatibility

- No inbound port is opened, so NAT and non-NAT machines use the same logic.
- WARP needs outbound UDP connectivity to Cloudflare's endpoint; if the provider blocks that path, validation can succeed but runtime probing may still fail, which is reported as an availability limitation.
- The script keeps the existing public endpoint profile for backward compatibility and does not include VPS-specific domains, tokens, addresses, or subscription settings.
- Prerequisite repair and selective service changes preserve existing custom rule sets, outbounds, endpoints, and unrelated route rules. Explicit global-proxy or restore-direct actions intentionally clear selective route rules because those actions request one default path for all traffic.

## Verification

Automated shell tests cover missing-file repair, preservation of custom entries, sniff rule insertion, native-IPv6 fallback behavior, service rule deletion, non-destructive global/restore behavior, and rollback on validation or restart failure. The existing subscription and Argo regression suite must remain green. A real sing-box configuration check is also run on the target VPS, followed by direct and WARP IPv4/IPv6 egress probes.
