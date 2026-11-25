# Synthetic examples

These examples contain no real account, credential, device, or public IP.

## Snapshot

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -Json

## Consistency check

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProxyConsistency.ps1 -SnapshotFile .\examples\snapshot-mismatch.json -Json

Expected: exit 2 and an issue saying UI and HKCU differ.

## Backup encryption round trip

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Protect-Backup.ps1 -Path <backup-dir> -OutFile <secure-dir>\backup.zip.dpapi -Apply
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Unprotect-Backup.ps1 -InFile <secure-dir>\backup.zip.dpapi -OutFile <restore-dir>\backup.zip

The plaintext original is not deleted. Verify the manifest SHA-256.
