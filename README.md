# mnemosync.ag

A Windows PowerShell + Python utility ([`Migrate-AntigravityWorkspace.ps1`](./Migrate-AntigravityWorkspace.ps1)) that preserves Antigravity IDE workspaces, VS Code extension/editor state, hot-exit backups, Antigravity 2.0 projects, and conversation metadata after renaming or moving a project root directory on Windows.

## Features

- **Exact Workspace Identity Calculation:** Computes the target `workspaceStorage\<md5>` hash from the lowercase-drive path and integer millisecond `birthtime`, and generates a canonical `workspace.json` (`file:///c%3A/...`, LF line endings).
- **Case-Insensitive Full-Path Rewriting:** Matches the full old path across raw Windows paths, percent-encoded and double percent-encoded URIs, JSON-escaped paths, and recursive/base64-wrapped Protobuf wire messages.
- **Broad Storage Coverage:** Updates `workspaceStorage`, `globalStorage` (`state.vscdb` + `storage.json`), `Backups` (`workspaces.json` + hot-exit `meta.json`), `.gemini\antigravity` / `.gemini\antigravity-ide` (`.db`, `.pb`, `.json`, `.md`, `.txt`, `.pbtxt`), `.gemini\config\projects\*.json`, and `.gemini\projects.json`.
- **Transactional SQLite Updates & Automatic Rollback:** Runs `PRAGMA integrity_check` before and after updates, truncates WAL journals, refreshes `state.vscdb.backup`, and automatically restores per-file backups (`Migration_FileBackup_*`) on error alongside a full `User_AutoBackup_*` snapshot.
- **Built-In Audit (`-Verify`):** Read-only verification report checking workspace hash alignment, SQLite integrity, sidebar protobuf consistency, Antigravity 2.0 project links, and leftover old-path references.
- **Verification-Gated Cleanup (`-Cleanup`):** Safely previews or deletes old/stale `workspaceStorage` entries, migrated `Backups\<hash>` folders, and (with `-IncludeBackups`) aged script backups—refusing to delete anything if verification fails.

## Requirements

- **OS:** Windows (`nt`)
- **PowerShell:** Windows PowerShell or PowerShell 7+ (`-ExecutionPolicy Bypass` if script execution is restricted)
- **Python 3:** `python` or `py -3` available in `PATH`
- **Closed Apps (for write operations):** Close both Antigravity IDE and the Antigravity agent app completely and run from an external PowerShell window. (`-Verify` and `-Cleanup` preview without `-Apply` are read-only.)

## Quick Start

> Rename or move your project folder on disk **first** while Antigravity is closed.

```powershell
# 1. Dry-run preview (no changes written)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name"

# 2. Apply migration + run automatic verification
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Apply

# 3. Standalone read-only verification
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Verify

# 4. Leftover cleanup preview & deletion (after confirming in Antigravity)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup

powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup -Apply
```

## Documentation

See [`RUNBOOK.md`](./RUNBOOK.md) for the complete operational runbook, including full parameter reference, cross-parent move and case-only rename examples, Verification Report interpretation, manual recovery commands, troubleshooting, and known limitations.

## License

Licensed under the [MIT License](./LICENSE).
