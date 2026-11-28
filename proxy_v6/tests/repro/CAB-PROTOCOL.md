# CAB protocol limits

Local evidence records what one observation can support. It does not establish production protection.

`CabProtocolLocal.ps1` looks up `example.com` through the current resolver and opens loopback sockets only. It does not change system DNS, the firewall, or the proxy, and it does not start a browser.

## Still not tested

- **System resolver path.** An answer for `example.com` shows that some resolver returned addresses. It does not identify the recursive resolver, cache, or proxy path that produced the answer.
- **Browser DoH.** An HTTP status, including a status from a loopback request, is not a browser DoH setting, negotiated resolver, fallback, or cache.
- **Public IPv6.** An exchange, refusal, or timeout on `[::1]` covers that loopback socket. It is not a public IPv6 address, route, or proxy path.
- **TURN.** WebRTC with no browser capture is `NotTested`. A TURN relay, a real call, and a browser ICE path are outside this check.
