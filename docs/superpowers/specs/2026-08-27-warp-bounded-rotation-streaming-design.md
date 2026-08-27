# Bounded WARP Rotation and Streaming Rule Repair Design

## Goal

Make the existing `更换内置 WARP 身份/IP` operation continue through several safe five-candidate batches until it obtains a genuinely different WARP IPv4 address, while keeping a firm attempt and time budget. Repair the `常见流媒体（聚合规则）` route so that Disney+, Hulu, Max, Prime Video, Spotify, Netflix, and YouTube are covered by the published rule set.

This change updates the public script and the disposable IPv4-only staging VPS. It must not modify the production DMIT VPS, the Windows host network configuration, or the host's network identity. It is not pushed to GitHub until separately requested.

## Rotation behavior

`rotate_warp_identity_once` remains the atomic transaction unit and keeps its existing five-candidate limit, candidate isolation, registration cleanup, transactional activation, rollback, and return-code contract:

- `0`: a different WARP IPv4 was committed successfully;
- `1`: the batch exhausted safe candidates and the active configuration is unchanged;
- `2`: cleanup, rollback, or state is uncertain and all automatic attempts must stop.

A new `rotate_warp_identity_until_new` wrapper calls that unit repeatedly. The production defaults are four batches, twenty candidates in total, and a ten-minute wall-clock limit. Test-only or advanced overrides may lower or raise those limits through environment variables, but values are validated and clamped to conservative bounds. The wrapper retries only return code `1`, stops immediately on `0` or `2`, checks the time budget before starting another batch, and prints the current batch and final stopping reason.

The menu dispatcher calls the wrapper instead of the single-batch function. It does not create an infinite loop and does not change the existing WARP endpoint unless the existing transaction commits a candidate whose probed IPv4 differs from the currently active IPv4.

## Streaming routing repair

The existing `streaming` tag and menu numbering remain unchanged. Its remote binary source changes from the incomplete `geo-lite/geosite/proxymedia.srs` file to MetaCubeX's full `geo/geosite/category-entertainment.srs` file.

The replacement was selected because its compiled contents include exact rules for the core services above. It avoids adding several new rule-set objects, preserves the existing route-rule shape, and has lower configuration and download overhead than maintaining a separate tag per platform.

All other rule sources and route behavior remain unchanged. Selected services route through `wireguard-out`; `route.final` remains `direct`, so unrelated traffic continues through the VPS native egress. The script does not enable global WARP or install a host WARP interface.

## Error handling and compatibility

Registration failure, candidate-probe failure, same-IP candidates, and ordinary exhaustion remain recoverable and leave the active identity untouched. Cloud-registration cleanup failure, local credential cleanup failure, validation failure with uncertain rollback, or another return code `2` condition terminates the outer loop immediately and preserves the existing recovery guidance.

The change adds no listeners, daemons, inbound ports, or persistent background work. It therefore preserves NAT VPS behavior and works on IPv4-only, IPv6-only, and dual-stack hosts to the same extent as the existing built-in WARP endpoint. Candidate processing remains sequential to keep CPU, memory, and API load low.

## Verification

Test-first coverage must prove that the wrapper:

- retries ordinary exhausted batches and stops on the first success;
- stops immediately on unsafe return code `2`;
- honors the batch and time limits;
- reports unchanged configuration after safe exhaustion;
- is used by menu option 6 without changing menu numbering.

Routing tests must prove that the generated `streaming` rule set uses the verified full source. On the staging VPS, a temporary localhost-only sing-box test instance must send real requests for Disney+, Hulu, Max, Prime Video, Spotify, Netflix, and YouTube through `wireguard-out`, while a control domain uses `direct`. The production sing-box configuration must still validate, existing selected rules must remain intact, and the live services must remain healthy after deployment.
