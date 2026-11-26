# mnemosync.ag

[![CI](https://github.com/asteroidcrib729/mnemosync.ag/actions/workflows/ci.yml/badge.svg)](https://github.com/asteroidcrib729/mnemosync.ag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

A Windows PowerShell + Python utility ([`Migrate-AntigravityWorkspace.ps1`](./Migrate-AntigravityWorkspace.ps1)) that preserves Antigravity IDE workspaces, VS Code extension/editor state, local edit history, hot-exit backups, Antigravity 2.0 projects, and conversation metadata/search indexes after renaming or moving a project root directory on Windows.

## Features

- **Exact Workspace Identity Calculation:** Computes the target `workspaceStorage\<md5>` hash from the lowercase-drive path and integer millisecond `birthtime`, and generates a canonical `workspace.json` (`file:///c%3A/...`, LF line endings).
- **Case-Insensitive Full-Path Rewriting:** Matches the full old path across raw Windows paths, percent-encoded and double percent-encoded URIs, JSON-escaped paths, and recursive/base64-wrapped Protobuf wire messages.
- **Complete Storage Coverage:** Updates `workspaceStorage` (both single-folder and multi-root `.code-workspace` entries + files), `User\History` (VS Code Local History), `globalStorage` (`state.vscdb` + `storage.json`), `Backups` (`workspaces.json` + hot-exit `meta.json`), `.gemini\antigravity` / `.gemini\antigravity-ide` (`.db`, `.pb`, `.json`, `.md`, `.txt`, `.pbtxt`, including `conversation_summaries.db` `conversations_fts`), `.gemini\config\projects\*.json`, and `.gemini\projects.json`.
- **Overwrite Protection & Transactional Rollback:** Protects newer populated target `state.vscdb` files during re-apply unless `-OverwriteExistingState` is passed, checks SQLite integrity before/after commits, and automatically restores per-file backups (`Migration_FileBackup_*`) on error alongside a full `User_AutoBackup_*` snapshot.
- **Optional On-Disk Rename (`-RenameOnDisk`):** Validates Antigravity is closed, renames the project folder (including case-only renames on NTFS), migrates metadata, and rolls back the folder rename if anything fails.
- **Built-In Audit (`-Verify`), Cleanup (`-Cleanup`), and Recovery (`-ListBackups` / `-Restore`):** Read-only verification checklist, verification-gated leftover cleanup, and one-command backup listing/restore.

## Requirements

- **OS:** Windows (`nt`)
- **PowerShell:** Windows PowerShell or PowerShell 7+ (`-ExecutionPolicy Bypass` if script execution is restricted)
- **Python 3:** `python` or `py -3` available in `PATH`
- **Closed Apps (for write operations):** Close both Antigravity IDE and the Antigravity agent app completely and run from an external PowerShell window. (`-Verify`, `-ListBackups`, `-Cleanup` preview, and `-Restore` preview are read-only.)

## Quick Start

> Rename or move your project folder on disk **first** while Antigravity is closed (or pass `-RenameOnDisk` to let the script rename it).

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

# 5. List backups or restore a prior migration snapshot
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -ListBackups
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -Restore -BackupStamp 20261126_120000 -Apply
```

## Documentation

See [`RUNBOOK.md`](./RUNBOOK.md) for the complete operational runbook, including full parameter reference, cross-parent move and case-only rename examples, Verification Report interpretation, backup recovery, troubleshooting, and known limitations.

## License

Licensed under the [MIT License](./LICENSE).
