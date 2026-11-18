# Reliability gaps and fail-closed coverage

This note distinguishes automatic reconnection, detection, and manual repair.
They are not the same thing.

## StarSky node change / first-hop interruption

Observed architecture: the local Clash profile dials a static SOCKS5 upstream
through a local HTTP first hop. Changing a StarSky node can:

- keep the local first-hop port listening while the upstream path changes;
- briefly fail new connections;
- break existing TCP sessions;
- leave the Windows system proxy still pointed at local Clash.

Expected behavior:

| Event | Current behavior | Automatic recovery? |
|---|---|---|
| StarSky node switch, port stays up | Existing sessions may fail; new sessions may recover if the path is healthy | No; detection only |
| First hop briefly down | Clash TCP requests fail; China-direct rules may still work | No; state reports DEGRADED/FAILED |
| First hop restarts | New connections may recover when the port returns | No explicit wait/reapply service |
| Windows proxy ownership overwritten | Browser path can change; state compares UI/HKCU | Detection only; Repair is manual |

Apply -Repair re-asserts the system proxy only after the chain exit probe is
healthy. It does not restart StarSky or Clash and does not repair a down first hop.
A successful detection is not an automatic repair.

## Windows login / startup

- Clash Verge has a logon scheduled task.
- V4 has no automatic startup task.
- StarSky's startup ordering was not guaranteed/verified.
- The Windows proxy setting persists across login. If Clash starts before the
  first hop is ready, foreign requests can fail until the path recovers; there
  is no watchdog or retry service.
- Do not add a startup task without explicit authorization; it can change the
  login network sequence.

## Fail-closed coverage

| Request type | If first hop/upstream fails | Leak risk / behavior |
|---|---|---|
| TCP through system proxy and matched to PROXY | Clash returns failure | No DIRECT fallback in the PROXY group; request fails |
| China destination matched GEOIP,CN,DIRECT | Direct connection continues | No static-proxy coverage; by design |
| UDP/WebRTC | Not carried by HTTP system proxy; upstream udp=false | May use direct/other path; not protected |
| App ignoring Windows proxy | Own socket path | Not controlled by system proxy |
| System proxy overwritten/off | Browser path changes | State should report mismatch/DEGRADED |

The proxy group removing DIRECT is not a system-wide kill switch. It only
prevents a DIRECT fallback inside Clash for matched proxy traffic. It does not
cover non-proxy-aware apps, UDP, DNS, or a disabled/overwritten OS proxy.

## Current state reporting

State output now includes:

- systemProxy and uiSystemProxy;
- udpProxied and pathScope (TCP_ONLY when upstream udp=false);
- warnings (UDP/WebRTC not proxied);
- reasons for UI mismatch, first-hop failure, missing settings, exit mismatch.

When upstream udp=false, the state is DEGRADED with pathScope TCP_ONLY, not
HEALTHY; the warning says UDP/WebRTC is not proxied. HEALTHY is reserved for a
measured path within its declared scope. It never means all applications, DNS,
or the whole machine are protected.

## Minimal improvement candidates

1. A read-only startup health check that reports first-hop order; no change to
   the login sequence without authorization.
2. A manual Repair wrapper that waits for the first-hop port and then reasserts
   the OS proxy; requires explicit authorization.
3. UDP-capable proxy/TUN only after provider data-plane verification.
4. Browser WebRTC policy or explicit user choice; not a silent change.