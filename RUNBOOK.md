# Antigravity Workspace Migration Runbook

Operational runbook for [`Migrate-AntigravityWorkspace.ps1`](./Migrate-AntigravityWorkspace.ps1) — migrating, verifying, cleaning up, and recovering Antigravity IDE and Antigravity 2.0 project workspaces after renaming or moving a project root folder on Windows.

---

## Table of Contents

1. [Overview & Scope of Changes](#1-overview--scope-of-changes)
2. [Prerequisites](#2-prerequisites)
3. [Parameter Reference](#3-parameter-reference)
4. [Step-by-Step Execution Procedure](#4-step-by-step-execution-procedure)
   - [Step 1 — Close Antigravity & Rename the Folder on Disk](#step-1--close-antigravity--rename-the-folder-on-disk)
   - [Step 2 — Dry-Run (Preview)](#step-2--dry-run-preview)
   - [Step 3 — Apply Migration (`-Apply`)](#step-3--apply-migration--apply)
   - [Step 4 — Verify Results](#step-4--verify-results)
   - [Step 5 — Leftover Cleanup (`-Cleanup`)](#step-5--leftover-cleanup--cleanup)
5. [Exit Codes](#5-exit-codes)
6. [Backups, Automatic Rollback & Manual Recovery](#6-backups-automatic-rollback--manual-recovery)
7. [Troubleshooting](#7-troubleshooting)
8. [Known Limitations](#8-known-limitations)
9. [Quick-Reference Cheat Sheet](#9-quick-reference-cheat-sheet)

---

## 1. Overview & Scope of Changes

When you rename or move a project directory on Windows, Antigravity stores workspace identity using an MD5 hash of the lowercase-drive filesystem path concatenated with the folder's integer creation timestamp (`birthtime` in milliseconds), plus URI and path references across VS Code state, hot-exit backups, protobuf blobs, and `.gemini` project/conversation files. Simply reopening the renamed folder causes Antigravity to treat it as a brand-new workspace or show a **"Different Workspace"** warning.

`Migrate-AntigravityWorkspace.ps1` preserves workspace state, extension state, sidebar entries, Antigravity 2.0 projects, and conversation metadata by matching the **full old path** case-insensitively (raw paths, percent-encoded and double percent-encoded URIs, JSON-escaped paths, and nested/base64-wrapped protobuf payloads) and rewriting it to the new path.

### Locations Updated

| Target | Path | What Changes |
| --- | --- | --- |
| Workspace storage | `%APPDATA%\<AppDataFolderName>\User\workspaceStorage\<md5>` | Computes the IDE's target `<md5>` hash, creates canonical `workspace.json` (`file:///c%3A/...`, LF line endings), and copies state/extension data from the old hash folder (preserving the new `workspace.json`). |
| Global SQLite state | `%APPDATA%\<AppDataFolderName>\User\globalStorage\state.vscdb` | Updates `ItemTable` entries (such as `history.recentlyOpenedPathsList`, `antigravityUnifiedStateSync.sidebarWorkspaces` including nested base64 protobufs, terminal/extension history). Syncs `state.vscdb.backup` if present. |
| Workspace SQLite state | `%APPDATA%\<AppDataFolderName>\User\workspaceStorage\<md5>\state.vscdb` | Updates `ItemTable` entries referencing the old path and syncs `state.vscdb.backup` if present. |
| Global JSON state | `%APPDATA%\<AppDataFolderName>\User\globalStorage\storage.json` | Traverses JSON and rewrites workspace/window path references. |
| Hot-exit backups | `%APPDATA%\<AppDataFolderName>\Backups\workspaces.json` & `Backups\<md5>\meta.json` | Updates `workspaces.json` and copies `Backups\<old_hash>` to `Backups\<new_hash>` (if not already present), rewriting `meta.json`. |
| Antigravity `.gemini` data | `%USERPROFILE%\.gemini\antigravity` & `%USERPROFILE%\.gemini\antigravity-ide` | Scans `.db` (SQLite tables), `.pb` (<= 50 MB), and `.json`, `.md`, `.txt`, `.pbtxt` (<= 10 MB). Skips `.system_generated`, `browser_recordings`, `tempmediastorage`, `node_modules`, `.git`, `cache`, `log`, `logs`, `bin`, `builtin`, `plugins`, `plugin_data`, `crashes`. |
| Antigravity 2.0 projects | `%USERPROFILE%\.gemini\config\projects\*.json` & `%USERPROFILE%\.gemini\projects.json` | Updates `projectResources` URIs, `permissionGrants` paths, project `name` (when matching the old folder name), and lowercase `projects.json` keys/values. |

---

## 2. Prerequisites

- **OS:** Windows only (the embedded engine exits if `os.name != "nt"`).
- **PowerShell:** Windows PowerShell (`powershell.exe`) or PowerShell 7+ (`pwsh.exe`), typically invoked with `-ExecutionPolicy Bypass` if local script signing is restricted.
- **Python 3:** `python` or `py -3` must be available in `PATH` (used for transactional SQLite and wire-level protobuf updates).
- **External Terminal & Closed Apps (for write operations):**
  - Both the **Antigravity IDE** and the **Antigravity agent app** must be completely closed before running a migration dry-run/apply or `-Cleanup -Apply`.
  - Run the script from an **external PowerShell window** (not Antigravity's integrated terminal, because Antigravity processes will still be running).
  - **Exception (read-only modes):** `-Verify`, and `-Cleanup` *without* `-Apply` (preview mode), are strictly read-only and are allowed while Antigravity is open (the script prints a `NOTE` reminding you that closing Antigravity yields the most reliable on-disk check).

### Pre-Flight Process & Lock Check

Before running a migration or `-Cleanup -Apply`, confirm no Antigravity processes or SQLite lock files remain:

```powershell
# 1. Must return nothing
Get-Process | Where-Object { $_.ProcessName -match "Antigravity" }

# 2. Must return nothing
Get-ChildItem -Path "$env:APPDATA\Antigravity IDE\User" -Recurse -Include "*.vscdb-wal", "*.vscdb-journal" -ErrorAction SilentlyContinue
```

---

## 3. Parameter Reference

| Parameter | Type / Default | Required | Description |
| --- | --- | --- | --- |
| `-NewProjectPath` | `string` | Yes | Existing (already renamed/moved) project root directory. |
| `-OldFolderName` | `string` | Yes | Old folder leaf name (e.g., `"old-name"`) or full old path (e.g., `"D:\OldParent\old-name"`). A leaf name is assumed to share the same parent directory as `-NewProjectPath`. Case-only renames (e.g., `MyApp` -> `myapp`) are supported. |
| `-AppDataFolderName` | `string` (`"Antigravity IDE"`) | No | Subfolder under `%APPDATA%` containing Antigravity's `User` and `Backups` directories. |
| `-Apply` | `switch` | No | Commits changes. Without `-Apply`, migration runs as a dry-run and `-Cleanup` runs as a preview. During migration, `-Apply` creates backups and runs the Verification Report automatically afterward. |
| `-Verify` | `switch` | No | Read-only audit that checks workspace hash, `workspace.json`, SQLite health and leftover old references, sidebar protobuf consistency, Antigravity 2.0 project link, and `.gemini` files. |
| `-Cleanup` | `switch` | No | Removes leftover old/duplicate `workspaceStorage` entries and migrated `Backups\<hash>` folders. Always runs `-Verify` first and refuses to delete if any check is `FAIL`. Never re-runs the migration itself. Preview by default; add `-Apply` to delete. |
| `-IncludeBackups` | `switch` | No | Used with `-Cleanup`: also includes aged script backups (`User_AutoBackup_*`, `Migration_FileBackup_*`, `.gemini\antigravity_AutoBackup_*`) older than `-KeepBackupDays`. The newest backup of each kind is always kept. |
| `-KeepBackupDays` | `int` (`7`, range `0`–`3650`) | No | Minimum age in days for `-IncludeBackups` to mark older backups for deletion. |

### Disallowed Switch Combinations

The script will immediately fail (`exit 1`) if you pass:

- `-Apply` together with `-Verify` (`-Apply` already runs verification after committing).
- `-Cleanup` together with `-Verify` (`-Cleanup` already runs verification first).
- `-IncludeBackups` without `-Cleanup`.

---

## 4. Step-by-Step Execution Procedure

### Step 1 — Close Antigravity & Rename the Folder on Disk

1. Save any open files and close **all** Antigravity IDE windows and the Antigravity agent app (check the system tray / Task Manager for lingering `Antigravity` background processes).
2. Rename or move the project folder on disk (Explorer, `Rename-Item`, `Move-Item`, etc.).
   - If you have not renamed the folder yet (and the old path still exists on disk), dry-run/apply will refuse with: `The old path still exists on disk: ... Rename/move the folder first.`
3. Open an **external** PowerShell terminal and `cd` to the directory containing `Migrate-AntigravityWorkspace.ps1`.

---

### Step 2 — Dry-Run (Preview)

Always preview first (omit `-Apply`). Nothing on disk is modified.

**Same-parent rename** (only the folder name changed):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name"
```

**Cross-parent move** (project moved to a different parent directory — pass the full old path):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "D:\Repos\new-project-name" `
  -OldFolderName "C:\OldFolder\old-project-name"
```

**Case-only rename** (e.g., `MyProject` -> `myproject` on Windows):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "C:\Repos\myproject" `
  -OldFolderName "MyProject"
```

#### What to Inspect in Dry-Run Output

Look for these tags in stdout before committing:

- `[Workspace]` — Shows `Source hash folder`, `Target hash folder` (or `Created target hash`), and `Copy state & extensions`. If an earlier broken run created an unused hash directory for the new folder, you will see `Ignoring entries for the new folder under unused hashes: ...`.
- `[Backups]` — Shows hot-exit backup folder migration (`Backups\<old_hash> -> Backups\<new_hash>`), if present.
- `[SQLite]` — Lists every database table/column/key to be updated (both `AppData` `state.vscdb` and `.gemini` `conversations\*.db`).
- `[JSON]` — `globalStorage/storage.json` and `Backups/workspaces.json`.
- `[Protobuf]` / `[Project]` / `[Metadata]` — `.pb`, Antigravity 2.0 project `.json`, `projects.json`, and text/markdown files under `.gemini`.
- Footer: `Items to update: <N>` and `Status: DRY RUN COMPLETE (re-run with -Apply to commit changes)`.

---

### Step 3 — Apply Migration (`-Apply`)

With Antigravity still completely closed, add `-Apply`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Apply
```

#### What Happens During `-Apply`

1. **Full `User` directory snapshot:** Copies `%APPDATA%\<AppDataFolderName>\User` to `User_AutoBackup_<yyyyMMdd_HHmmss>`.
2. **Per-file backups:** Every individual file modified (including SQLite DBs via `sqlite3.Connection.backup()` and files under `.gemini`) is backed up into `%APPDATA%\<AppDataFolderName>\Migration_FileBackup_<yyyyMMdd_HHmmss>` with an append-only `manifest.jsonl`.
3. **Workspace & Backups copy:** Creates the target `workspaceStorage\<md5>` and canonical `workspace.json` if missing, copies state/extension data, and copies hot-exit `Backups\<old_hash>`.
4. **Transactional SQLite updates:** Runs `PRAGMA integrity_check` before and after `BEGIN IMMEDIATE ... COMMIT`, executes `PRAGMA wal_checkpoint(TRUNCATE)`, and refreshes `state.vscdb.backup` if it exists.
5. **Automatic post-apply verification:** Runs the read-only Verification Report immediately after `Status: APPLIED SUCCESSFULLY`. Expect roughly 30 seconds total depending on the size of `.gemini\antigravity\conversations`.

> [!NOTE]
> If any unexpected exception occurs during `-Apply`, the engine automatically deletes newly tracked directories/files and restores every backed-up file from `Migration_FileBackup_<stamp>`.

---

### Step 4 — Verify Results

#### 4A. Automated Verification (`-Verify`)

`-Apply` runs this automatically at the end, and you can re-run it standalone at any time (even while Antigravity is running):

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Verify
```

#### Interpreting the Verification Report

| Check / Status | Meaning | Action Needed |
| --- | --- | --- |
| `[PASS] Workspace storage exists under the hash the IDE computes for the new folder` | The folder exists at the exact MD5 hash Antigravity calculates from path + creation time. | None. |
| `[PASS] workspace.json points to the new folder (canonical URI)` | `workspace.json` matches `file:///c%3A/...`. (`[WARN]` if path matches but URI formatting is non-canonical; `[FAIL]` if wrong/missing.) | Re-run with `-Apply` if `[FAIL]`. |
| `[PASS] Workspace state database is healthy` / `no references to the old path` | `state.vscdb` passes `PRAGMA integrity_check` and has no leftover old-path entries. | Re-run with `-Apply` if `[FAIL]`. |
| `[PASS] Global state database is healthy` / `no references to the old path` | `globalStorage\state.vscdb` passes integrity check and has no old-path references. | Re-run with `-Apply` if `[FAIL]`. |
| `[PASS] New folder is in the recently-opened list` | `history.recentlyOpenedPathsList` contains the new path. (`[WARN]` if the folder hasn't been opened once yet.) | Open the folder once in Antigravity if `[WARN]`. |
| `[PASS] Sidebar workspace list is valid and lists the new folder consistently` | `sidebarWorkspaces` protobuf is valid and updated in **both** plain text and nested base64 entries. (`[FAIL]` if corrupted or only one copy updated.) | Re-run with `-Apply` if `[FAIL]`. |
| `[PASS] storage.json and hot-exit Backups contain no references to the old path` | `globalStorage\storage.json` and `Backups\workspaces.json` are clean. | Re-run with `-Apply` if `[FAIL]`. |
| `[PASS] An Antigravity project is linked to the new folder` | Found one `~\.gemini\config\projects\*.json` pointing to the new folder. (`[WARN]` if none or multiple.) | Expected `[WARN]` if the folder was never added as an Antigravity 2.0 project. |
| `[PASS] Project files ...` / `Workspace summary/index files ...` | No old path references remain in `config\projects`, `projects.json`, `.pb`, `agyhub*`, or `antigravity_state*`. | Re-run with `-Apply` if `[FAIL]`. |
| `[WARN] N conversation/metadata entries still mention the old path` | Old path strings still appear in conversation DBs or `.md`/`.txt` metadata (often chat messages quoting the old path). | Informational only; does not fail verification. |
| `[INFO] Extra workspace entries ...` / `Old workspace entry still on disk` | Harmless duplicate hash folder or old workspace safety copy still on disk. | Remove with `-Cleanup` once satisfied. |

**Verdicts:**

- `VERIFIED - all checks passed.` (`exit 0`)
- `VERIFIED with N warning(s) - the workspace link is intact; warnings are informational.` (`exit 0`)
- `NOT VERIFIED - N check(s) failed. Re-run with -Apply (Antigravity closed), then -Verify again.` (`exit 2`)

#### 4B. Visual Confirmation in Antigravity

Reopen the renamed folder in Antigravity and confirm:

1. **No "Different Workspace" warning** appears.
2. **Restored IDE state:** Previous open tabs, panel layout, and extension workspace state are intact.
3. **Sidebar & Recents:** The workspace appears under its new name/path in the sidebar and Recently Opened list.
4. **Projects & Conversations:** Your Antigravity 2.0 project and prior conversation threads remain linked to the renamed folder.

---

### Step 5 — Leftover Cleanup (`-Cleanup`)

After confirming everything works in Antigravity, use `-Cleanup` to safely remove old/stale workspace folders left behind on disk.

#### 5A. Preview Cleanup (Read-Only)

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup
```

To also preview pruning aged backup directories created by the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup -IncludeBackups -KeepBackupDays 7
```

#### 5B. Execute Cleanup (`-Cleanup -Apply`)

Close Antigravity completely, then add `-Apply`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup -Apply
```

With optional backup pruning:

```powershell
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 `
  -NewProjectPath "$env:USERPROFILE\Downloads\Source-Code\new-project-name" `
  -OldFolderName "old-project-name" `
  -Cleanup -Apply -IncludeBackups -KeepBackupDays 7
```

#### What `-Cleanup` Targets & Safety Rails

- **Targets removed:**
  1. `User\workspaceStorage\<old_hash>` (old workspace entry whose state was migrated).
  2. `User\workspaceStorage\<stale_hash>` (any unused hash folder pointing to the new path, such as leftovers from earlier runs).
  3. `Backups\<hash>` for those removed entries — **only if** `Backups\<live_hash>` exists on disk; otherwise `[KEEP]` is printed so unsaved hot-exit files are never lost.
  4. *(Only when `-IncludeBackups` is passed)* `User_AutoBackup_<stamp>`, `Migration_FileBackup_<stamp>` (under `%APPDATA%\<AppDataFolderName>`), and `antigravity_AutoBackup_<stamp>` (under `%USERPROFILE%\.gemini`) older than `-KeepBackupDays`.
- **Built-in safety rails:**
  - **Verification gate:** Runs `-Verify` first and **refuses** to delete anything (`exit 2`) if any check reports `FAIL`.
  - **Never re-runs migration:** Prevents overwriting newer workspace state accumulated after reopening the project.
  - **Live entry protection:** Enforces exact parent directory, 32-char hex or backup-timestamp regex match, non-symlink check, and explicitly forbids deleting `exp_dir` (the live target hash).
  - **Newest backup retention:** Even with `-IncludeBackups -KeepBackupDays 0`, the newest backup of each type (`User_AutoBackup`, `Migration_FileBackup`, `antigravity_AutoBackup`) is always kept (`[KEEP]`).

---

## 5. Exit Codes

| Exit Code | Meaning |
| --- | --- |
| `0` | Success (dry-run completed, `-Apply` succeeded and verified, `-Verify` passed with 0 `FAIL`s, or `-Cleanup` preview/deletion succeeded). |
| `1` | Input validation error, disallowed parameter combination, Antigravity still running / SQLite lock files present (on write runs), Python missing, unhandled exception, or one or more `-Cleanup -Apply` deletions failed. |
| `2` | Verification reported one or more `FAIL` checks (either during `-Verify`, post-apply verification, or the `-Cleanup` safety gate where cleanup was refused). |

---

## 6. Backups, Automatic Rollback & Manual Recovery

### Backup Artifacts Created by `-Apply`

1. **`%APPDATA%\<AppDataFolderName>\User_AutoBackup_<yyyyMMdd_HHmmss>\`**
   Full recursive copy of the `User` directory taken before any edits.
2. **`%APPDATA%\<AppDataFolderName>\Migration_FileBackup_<yyyyMMdd_HHmmss>\`**
   Contains numbered copies (`00001_state.vscdb`, `00002_storage.json`, etc.) of every individual file modified (including `.gemini` DBs, `.pb`, and `.json` files) plus `manifest.jsonl` recording each original path (`{"orig": "...", "backup": "..."}`) and newly created path (`{"created": "..."}`).

### Automatic Rollback

If a runtime error occurs inside the Python engine during `-Apply`:

- All files recorded in `manifest.jsonl` are restored in reverse order (after removing any `-wal`, `-shm`, or `-journal` sidecars).
- Any newly created files/directories tracked during the run are deleted.
- Check the console output to confirm `[Rollback] Original state restored.`

### Manual Recovery

If you need to revert a completed migration manually (for example, after reopening Antigravity or renaming the folder back):

1. **Close Antigravity completely** (confirm via Task Manager / `Get-Process`).
2. **Restore the `User` directory** from `User_AutoBackup_<stamp>`:

   ```powershell
   $stamp = "20261125_210000"  # replace with your backup timestamp
   $appRoot = "$env:APPDATA\Antigravity IDE"
   Remove-Item -LiteralPath "$appRoot\User" -Recurse -Force
   Copy-Item -LiteralPath "$appRoot\User_AutoBackup_$stamp" -Destination "$appRoot\User" -Recurse -Force
   ```

3. **Restore `.gemini` (and any other) modified files** from `Migration_FileBackup_<stamp>\manifest.jsonl`:

   ```powershell
   $stamp = "20261125_210000"  # replace with your backup timestamp
   $bakDir = "$env:APPDATA\Antigravity IDE\Migration_FileBackup_$stamp"
   $lines = Get-Content -LiteralPath "$bakDir\manifest.jsonl"
   [array]::Reverse($lines)
   foreach ($line in $lines) {
       $entry = $line | ConvertFrom-Json
       if ($entry.orig -and $entry.backup) {
           foreach ($ext in "-wal", "-shm", "-journal") {
               Remove-Item -LiteralPath ($entry.orig + $ext) -Force -ErrorAction SilentlyContinue
           }
           Copy-Item -LiteralPath $entry.backup -Destination $entry.orig -Force
       } elseif ($entry.created -and (Test-Path -LiteralPath $entry.created)) {
           Remove-Item -LiteralPath $entry.created -Recurse -Force
       }
   }
   ```

4. If you also ran `-Cleanup -Apply` after migrating, the old `workspaceStorage\<old_hash>` is still preserved inside `User_AutoBackup_<stamp>\workspaceStorage\`.

---

## 7. Troubleshooting

| Symptom / Error | Cause & Resolution |
| --- | --- |
| `ERROR: Antigravity is currently running...` | Close all IDE and agent app windows, end remaining `Antigravity` tasks in Task Manager, and run the script from an external PowerShell window. |
| `ERROR: Active SQLite lock files (.vscdb-wal / .vscdb-journal) found.` | Antigravity recently closed or left a background worker holding a SQLite WAL/journal file. Wait a few seconds or terminate remaining `Antigravity` processes, then verify no `.vscdb-wal` / `.vscdb-journal` files remain before retrying. |
| `ERROR: The old path still exists on disk: ...` | Rename or move the project folder on disk **first**, then run the script against the new path. |
| `ERROR: Python 3 is required in PATH...` | Install Python 3 and ensure `python` or `py -3` resolves in PowerShell (`Get-Command python, py`). |
| `Multiple vanished workspaceStorage folders match '<name>'` | Two or more missing workspaces share the same leaf folder name. Pass the **full old path** as `-OldFolderName` (e.g., `-OldFolderName "C:\OldDir\my-app"`). |
| `[Workspace] No source workspaceStorage folder matched ...` | Verify `-OldFolderName` spelling, or pass the full old path if the folder was moved from another parent directory. Check `%APPDATA%\Antigravity IDE\User\workspaceStorage\*\workspace.json`. |
| Opened the renamed folder *before* running the script | Still recoverable: close Antigravity and run `-Apply` normally. The script copies your old workspace state into the target hash folder (keeping `workspace.json`) and ignores/flags any mismatched hash folders for `-Cleanup`. |
| `NOT VERIFIED - N check(s) failed` (`exit 2`) after `-Apply` | Review the `[FAIL]` lines in the Verification Report. Most commonly Antigravity was open or a file was locked; close Antigravity and re-run `-Apply`, then verify again. |
| PowerShell blocks running `.ps1` (`ExecutionPolicy`) | Invoke with `powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 ...`. |

---

## 8. Known Limitations

- **Compressed or encrypted blobs:** Binary payloads that are compressed or encrypted cannot be decoded as protobuf or UTF-8 text and are left untouched.
- **SQLite special tables skipped:** `sqlite_*` internal tables, `VIRTUAL TABLE`s (such as FTS5 full-text search indexes in `conversation_summaries.db`), and `WITHOUT ROWID` tables are intentionally skipped.
- **Local edit history:** `%APPDATA%\<AppDataFolderName>\User\History` (VS Code local file timeline snapshots) is not migrated.
- **`.gemini` file size caps:** Protobuf `.pb` files larger than **50 MB** and `.json`/`.md`/`.txt`/`.pbtxt` files larger than **10 MB** are skipped during `.gemini` scanning.
- **Platform:** Designed for **Windows** only (`%APPDATA%`, Win32 `GetFileAttributesExW` file creation time, and Windows drive-letter URIs).

---

## 9. Quick-Reference Cheat Sheet

```powershell
# 1. Dry-run preview (Antigravity closed)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "C:\Path\To\new-name" -OldFolderName "old-name"

# 2. Apply migration + automatic verification (Antigravity closed)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "C:\Path\To\new-name" -OldFolderName "old-name" -Apply

# 3. Standalone verification (read-only, safe anytime)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "C:\Path\To\new-name" -OldFolderName "old-name" -Verify

# 4. Leftover cleanup preview (read-only)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "C:\Path\To\new-name" -OldFolderName "old-name" -Cleanup

# 5. Delete verified leftovers + prune script backups older than 7 days (Antigravity closed)
powershell -ExecutionPolicy Bypass -File .\Migrate-AntigravityWorkspace.ps1 -NewProjectPath "C:\Path\To\new-name" -OldFolderName "old-name" -Cleanup -Apply -IncludeBackups -KeepBackupDays 7
```
