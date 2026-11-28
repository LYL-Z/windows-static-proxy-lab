# Operator boundary

Read this before acting. These limits override a diagnose sentence and a guess about what would help.

- **read-only until a specific change is accepted.** Inventory and diagnosis are not permission to write. Name one change, its scope, and its rollback, then wait until that change is accepted. Until then, do not download, install, start, stop, or edit network settings.
- **no-modify wins over diagnose.** “保持原配置，不擅自修改” or “不要修改” is the `no-modify` intent. `Resolve-ProxyDoctorUserRequest` returns that intent before any diagnose phrase. Do not turn the request into a repair. If the user also asked for a check, run only the requested read-only checks.
- **do not promise unban.** A proxy check, a setting change, or a client restart is not account recovery. Do not say a restriction will be lifted.

**StarSky restart is not acceleration.** Starting StarSky again, reopening its switch, or a UI status does not show that the upstream path is working. Check the listener and a new request separately. Do not restart StarSky unless that specific change was accepted.

A diagnose route stays `read-only until the user accepts one specific change`.
