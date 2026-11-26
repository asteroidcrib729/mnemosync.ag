# mnemosync.ag

[![CI](https://github.com/asteroidcrib729/mnemosync.ag/actions/workflows/ci.yml/badge.svg)](https://github.com/asteroidcrib729/mnemosync.ag/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Dedicated native migration utilities for **Windows**, **Linux**, and **macOS** that preserve Antigravity IDE workspaces, VS Code extension/editor state, local edit history, hot-exit backups, Antigravity 2.0 projects, and conversation metadata/search indexes after renaming or moving a project root directory:

- **Windows:** [`Migrate-AntigravityWorkspace.ps1`](./Migrate-AntigravityWorkspace.ps1)
- **Linux:** [`migrate-antigravity-workspace-linux.sh`](./migrate-antigravity-workspace-linux.sh)
- **macOS:** [`migrate-antigravity-workspace-macos.sh`](./migrate-antigravity-workspace-macos.sh)

## Features

- **Exact Platform Workspace Identity:** Computes the target `workspaceStorage/<md5>` hash the way Antigravity IDE does on each OS — lowercase-drive path + integer ms `birthtime` on Windows, path + `st_ino` on Linux, and path + integer ms `birthtime` on macOS — and writes a canonical `workspace.json`.
- **Full-Path Rewriting:** Matches the full old path (case-insensitively on Windows/macOS, case-sensitively on Linux) across raw paths, percent-encoded and double percent-encoded URIs, JSON-escaped paths, and recursive/base64-wrapped Protobuf wire messages.
- **Complete Storage Coverage:** Updates `workspaceStorage` (both single-folder and multi-root `.code-workspace` entries + files), `User/History` (VS Code Local History), `globalStorage` (`state.vscdb` + `storage.json`), `Backups` (`workspaces.json` + hot-exit `meta.json`), `.gemini/antigravity` & `.gemini/antigravity-ide` (`.db`, `.pb`, `.json`, `.md`, `.txt`, `.pbtxt`, including `conversation_summaries.db` `conversations_fts`), `.gemini/config/projects/*.json`, and `.gemini/projects.json`.
- **Overwrite Protection & Transactional Rollback:** Protects newer populated target `state.vscdb` files during re-apply unless `-OverwriteExistingState` / `--overwrite-existing-state` is passed, checks SQLite integrity before/after commits, and automatically restores per-file backups (`Migration_FileBackup_*`) on error alongside a full `User_AutoBackup_*` snapshot.
- **Optional On-Disk Rename (`-RenameOnDisk` / `--rename-on-disk`):** Validates Antigravity is closed, renames the project folder (including case-only renames on NTFS/APFS), migrates metadata, and rolls back the folder rename if anything fails.
- **Built-In Audit, Cleanup & Recovery:** Read-only `-Verify` / `--verify`, verification-gated `-Cleanup` / `--cleanup`, and one-command `-ListBackups` / `--list-backups` and `-Restore` / `--restore`.

## Requirements

- **OS & Shell:**
  - **Windows:** PowerShell (`-ExecutionPolicy Bypass` if script execution is restricted)
  - **Linux:** Bash (`migrate-antigravity-workspace-linux.sh`, uses `${XDG_CONFIG_HOME:-$HOME/.config}/Antigravity IDE`)
  - **macOS:** Bash/zsh (`migrate-antigravity-workspace-macos.sh`, uses `~/Library/Application Support/Antigravity IDE`)
- **Python 3:** `python` / `py -3` (Windows) or `python3` (Linux/macOS) in `PATH` (standard library only — no third-party packages required)
- **Closed Apps (for write operations):** Close both Antigravity IDE and the Antigravity agent app completely and run from an external terminal. (Verify, list-backups, cleanup preview, and restore preview are read-only.)

## Quick Start

> Rename or move your project folder on disk **first** while Antigravity is closed (or pass `-RenameOnDisk` / `--rename-on-disk`).

### Windows (PowerShell)

```powershell
# 1. Dry-run preview (no changes written)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name"

# 2. Apply migration + automatic verification
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Apply

# 3. Standalone verify, leftover cleanup, and backup restore
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" -OldFolderName "old-project-name" -Verify
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" -OldFolderName "old-project-name" -Cleanup -Apply
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -ListBackups
```

### Linux (Bash)

```bash
chmod +x ./migrate-antigravity-workspace-linux.sh

# 1. Dry-run preview
./migrate-antigravity-workspace-linux.sh --new-project-path "$HOME/src/new-project-name" --old-folder-name "old-project-name"

# 2. Apply migration + automatic verification
./migrate-antigravity-workspace-linux.sh --new-project-path "$HOME/src/new-project-name" --old-folder-name "old-project-name" --apply

# 3. Verify, cleanup, and backup restore
./migrate-antigravity-workspace-linux.sh --new-project-path "$HOME/src/new-project-name" --old-folder-name "old-project-name" --verify
./migrate-antigravity-workspace-linux.sh --new-project-path "$HOME/src/new-project-name" --old-folder-name "old-project-name" --cleanup --apply
./migrate-antigravity-workspace-linux.sh --list-backups
```

### macOS (Terminal)

```bash
chmod +x ./migrate-antigravity-workspace-macos.sh

# 1. Dry-run preview
./migrate-antigravity-workspace-macos.sh --new-project-path "$HOME/Projects/new-project-name" --old-folder-name "old-project-name"

# 2. Apply migration + automatic verification
./migrate-antigravity-workspace-macos.sh --new-project-path "$HOME/Projects/new-project-name" --old-folder-name "old-project-name" --apply

# 3. Verify, cleanup, and backup restore
./migrate-antigravity-workspace-macos.sh --new-project-path "$HOME/Projects/new-project-name" --old-folder-name "old-project-name" --verify
./migrate-antigravity-workspace-macos.sh --new-project-path "$HOME/Projects/new-project-name" --old-folder-name "old-project-name" --cleanup --apply
./migrate-antigravity-workspace-macos.sh --list-backups
```

## Documentation

See [`RUNBOOK.md`](./RUNBOOK.md) for the complete operational runbook, including full parameter reference, Linux/macOS notes, cross-parent move and case-only rename examples, Verification Report interpretation, backup recovery, troubleshooting, and known limitations.

## License

Licensed under the [MIT License](./LICENSE).
