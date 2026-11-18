# Targeted findings (2026-11-18, read-only)

These findings are diagnostic, not a claim that every hypothesis was reproduced
in an isolated lab. No production network settings were changed for this note.

## 1. China-direct rule change

Old effective Clash profile:

- proxy-group: fallback over the static SOCKS5 upstream and DIRECT
- rules: MATCH,PROXY (all destinations go through the group)

Current effective profile:

- proxy-group: select over the static SOCKS5 upstream
- rules: GEOIP,CN,DIRECT then MATCH,PROXY

Observed before: HTTPS to Baidu returned 502 when all traffic used the overseas
static chain. Observed after: Baidu returned 200 via the same Clash listener,
with China destinations taking DIRECT. The most likely cause is the overseas
exit IP / upstream path for a China site, not a broken local mixed port.
Confidence: high from the rule diff plus before/after status; an isolated
reproduction with the old profile was deliberately not run because it would
require changing or duplicating live credentials.

Is GEOIP,CN,DIRECT too broad?

- It matches destination IP country, not domain intent. A foreign service using
  a China CDN/endpoint can go DIRECT; a China service with a non-CN IP can go
  PROXY.
- It has no explicit private/LAN, domain, or process exceptions. Windows
  ProxyOverride covers typical local addresses, but apps using raw sockets can
  bypass the OS proxy entirely.
- It relies on the GeoIP database's country mapping and freshness; Hong
  Kong/Macau/Taiwan classification must be checked in the specific database.
- It is a reasonable simple default for usable China browsing, but it is broad.
  Add only evidence-driven exceptions (private ranges, known domains) rather
  than a large hand-maintained list.

## 2. SOCKS5 UDP ASSOCIATE

Test path: local SOCKS5 client -> HTTP CONNECT through the local first hop ->
static SOCKS5 upstream -> authenticated UDP ASSOCIATE request.

Result:

- HTTP CONNECT to the upstream: 200.
- SOCKS5 username/password method: selected (0x02), auth success.
- UDP ASSOCIATE reply: REP=0 (success), BND port allocated.
- This proves the upstream server implements the SOCKS5 UDP ASSOCIATE control
  command and returns a relay endpoint.

What is not proven:

- Actual UDP data-plane relay through that endpoint. The relay endpoint may be
  reachable only from the upstream side, and no UDP echo/DNS exchange was sent.
- The current Clash/Mihomo profile explicitly sets udp:false for the upstream
  and ipv6:false. So even with provider control support, the current client
  config disables UDP for that proxy.
- Distinguish three layers: protocol supports UDP ASSOCIATE; provider accepts
  the command; client config currently disables it. Do not claim "UDP works"
  from REP=0 alone.

## 3. Why WebRTC pages disagree

Observed pattern: one page reported a China/ISP IPv4 exit, another reported the
static proxy for HTTPS, and a WebRTC test reported the StarSky/direct UDP exit.

Explanation:

- An HTTP system proxy carries TCP/HTTP(S), not arbitrary UDP.
- WebRTC uses STUN/TURN over UDP; with TUN disabled and udp:false upstream, it
  can use the host/direct path (StarSky) independently of HTTPS.
- Test pages use different STUN servers, timeouts, caching, browser flags, and
  sometimes server-side versus browser-side checks. A green/red badge is not a
  protocol-level truth.
- TCP exit, DNS resolver, and UDP/WebRTC exit can legitimately differ. That is a
  privacy/split-path finding, not proof that the static proxy failed.

## 4. Real defects and candidate options

| Candidate | Benefit | Cost/risk |
|---|---|---|
| Keep current China-direct + static HTTPS | Usable China sites, static HTTPS path | WebRTC/UDP bypass, broad GEOIP |
| Add private/LAN direct rules | Avoid sending LAN traffic to proxy | Small rule change; test required |
| Add domain exceptions | Correct CN-CDN/foreign-service edge cases | Maintenance, domain drift |
| Enable upstream udp:true and TUN | Capture UDP/WebRTC | Invasive; may break DNS/apps; need provider data-plane test |
| Disable WebRTC in browser policy | Reduce UDP leak | Browser policy change; user decision |
| Startup watchdog for first-hop order | Faster recovery after login | New process/task; not yet justified |

No candidate was applied in this diagnostic. The current production network was
left unchanged; only the Skill branch was updated.

## 5. Rule of evidence

Report layers separately: UI, HKCU/WinHTTP, listener, first hop, DNS, TCP,
UDP/WebRTC, exit. A single green page, a ping, or a third-party IP score is not
a full health or eligibility verdict.
