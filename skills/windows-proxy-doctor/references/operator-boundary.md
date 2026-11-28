# Operator boundary

Read this before acting. These limits override a diagnose sentence and a guess about what would help.

This page owns two rules. They are stated here and nowhere else in this skill:

- **do not promise unban.** A proxy check, a change to a setting, or a client restart is not account recovery. Do not say a restriction will be lifted, shortened, or made less likely.
- **StarSky restart is not acceleration.** Starting StarSky again, reopening its switch, or a UI status does not show that the upstream path is working. Check the listener and a new request separately. Do not restart StarSky unless that specific change was accepted.

This page does not restate the other two. Follow the owner instead:

- `read-only until a specific change is accepted` → [safety](safety.md) "Authorization" (default read-only; separate authorization for each surface) and the `authorization` value reported by `scripts/ProxyFaultClass.ps1`.
- `no-modify wins over diagnose` → `Resolve-ProxyDoctorUserRequest` in `scripts/ProxyFaultClass.ps1` returns that intent before any diagnose phrase, and [troubleshooting](troubleshooting.md) covers the resulting `no-modify` route. Do not turn a no-modify request into a repair.

A diagnose route stays `read-only until the user accepts one specific change`.
