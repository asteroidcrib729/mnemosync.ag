<#
.SYNOPSIS
    Preserves Antigravity workspaces / projects after a project root directory was renamed.

.DESCRIPTION
    Run AFTER renaming the folder on disk, with Antigravity (IDE + agent app) fully closed.
    Dry-run by default; pass -Apply to commit changes.

    Updates (every reference to the OLD full path is rewritten, case-insensitively, in raw,
    percent-encoded, JSON-escaped and base64-wrapped protobuf form):
      * <AppData>\<AppDataFolderName>\User\workspaceStorage\<md5>   (state copied to the new hash)
      * <AppData>\<AppDataFolderName>\User\globalStorage\{state.vscdb, storage.json}
      * <AppData>\<AppDataFolderName>\Backups\{workspaces.json, <hash>\...}
      * ~\.gemini\antigravity, ~\.gemini\antigravity-ide    (.db / .pb / .json / .md / .txt / .pbtxt)
      * ~\.gemini\config\projects\*.json, ~\.gemini\projects.json   (Antigravity 2.0 projects)

.PARAMETER NewProjectPath
    Existing (already renamed) project directory.
.PARAMETER OldFolderName
    Old folder name (leaf) or the full old path. A leaf name is assumed to live in the same parent as the new path.
.PARAMETER Apply
    Commit changes. Every modified file is backed up first and restored automatically on failure.
    A read-only verification report is printed automatically after a successful apply.
.PARAMETER Verify
    Read-only audit: confirms the migration took effect (workspace hash, state databases, sidebar list,
    Antigravity projects, conversation index) and lists any remaining references to the old path.
    Prints a PASS/WARN/FAIL checklist and a verdict; exit code 2 if any check fails. Safe to run any time.
.PARAMETER Cleanup
    Leftover cleanup AFTER a migration. Runs the verification first and refuses to delete anything unless
    it has no FAIL results. Targets: the old workspaceStorage entry, stale duplicate entries for the new
    folder, and their hot-exit Backups folders. Preview by default; add -Apply to really delete.
    Never re-runs the migration itself.
.PARAMETER IncludeBackups
    With -Cleanup: also delete the script's own safety backups (User_AutoBackup_*, Migration_FileBackup_*,
    .gemini\antigravity_AutoBackup_*) older than -KeepBackupDays. The newest backup of each kind is always kept.
.PARAMETER KeepBackupDays
    Age threshold in days for -IncludeBackups (default 7).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$NewProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$OldFolderName,

    [string]$AppDataFolderName = "Antigravity IDE",

    [switch]$Apply,

    [switch]$Verify,

    [switch]$Cleanup,

    [switch]$IncludeBackups,

    [ValidateRange(0, 3650)]
    [int]$KeepBackupDays = 7
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

if ($Apply -and $Verify) {
    Fail "-Apply and -Verify cannot be combined. -Apply already runs the verification report when it finishes."
}
if ($Cleanup -and ($Verify)) {
    Fail "-Cleanup already runs the verification report first; do not combine it with -Verify."
}
if ($IncludeBackups -and -not $Cleanup) {
    Fail "-IncludeBackups only applies together with -Cleanup."
}
# Read-only runs: -Verify, or -Cleanup without -Apply (preview). They may run while Antigravity is open.
$ReadOnlyRun = $Verify -or ($Cleanup -and -not $Apply)

# 1. Validate inputs
if (-not (Test-Path -LiteralPath $NewProjectPath -PathType Container)) {
    Fail "Target project directory does not exist: $NewProjectPath"
}

$ResolvedNewPath = (Resolve-Path -LiteralPath $NewProjectPath).Path.TrimEnd('\', '/')
$NewLeafName     = Split-Path -Leaf $ResolvedNewPath
$TrimmedOld      = $OldFolderName.Trim().TrimEnd('\', '/')
$OldLeafName     = Split-Path -Leaf $TrimmedOld

if ($TrimmedOld -match '^[A-Za-z]:[\\/]') {
    $OldFullPath = $TrimmedOld
} else {
    $OldFullPath = Join-Path (Split-Path $ResolvedNewPath -Parent) $OldLeafName
}

if ([string]::IsNullOrWhiteSpace($OldLeafName)) {
    Fail "OldFolderName must not be empty."
}
# Case-sensitive comparison: a case-only rename (Foo -> foo) is a legitimate rename on Windows.
if ($OldFullPath -ceq $ResolvedNewPath) {
    Fail "Old path ('$OldFullPath') and target path are identical; nothing to migrate."
}
if (($OldFullPath -ine $ResolvedNewPath) -and (Test-Path -LiteralPath $OldFullPath) -and -not $Verify -and -not $Cleanup) {
    Fail "The old path still exists on disk: $OldFullPath. Rename/move the folder first."
}

$AppDataRoot = Join-Path $env:APPDATA $AppDataFolderName
$UserDir     = Join-Path $AppDataRoot "User"
$GeminiRoot  = Join-Path $env:USERPROFILE ".gemini"

if (-not (Test-Path -LiteralPath $UserDir -PathType Container)) {
    Fail "Antigravity User directory not found: $UserDir"
}

# 2. Ensure Antigravity is completely closed and no SQLite locks exist
$running = Get-Process | Where-Object { $_.ProcessName -match "Antigravity" }
if ($running -and $ReadOnlyRun) {
    Write-Host "NOTE: Antigravity is running. This run is read-only and checks what is on disk right now; close Antigravity first for the most reliable result." -ForegroundColor Yellow
} elseif ($running) {
    Fail "Antigravity is currently running. Close all windows (IDE and agent app) and terminate background processes in Task Manager first."
}

$locks = if ($ReadOnlyRun) { $null } else { Get-ChildItem -Path $UserDir -Recurse -Include "*.vscdb-wal", "*.vscdb-journal" -ErrorAction SilentlyContinue }
if ($locks) {
    Fail "Active SQLite lock files (.vscdb-wal / .vscdb-journal) found. Close Antigravity completely before running."
}

# 3. Locate Python 3
$pythonExe  = $null
$pythonArgs = @()
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonExe = "python"
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $pythonExe  = "py"
    $pythonArgs = @("-3")
} else {
    Fail "Python 3 is required in PATH to perform transactional SQLite and Protobuf wire-level updates."
}

# 4. Safety copies (Apply only). The Python engine additionally backs up every individual file
#    it touches and restores them automatically if anything fails.
$userBackupPath = $null
$fileBackupDir  = ""
if ($Apply -and -not $Cleanup) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $userBackupPath = Join-Path $AppDataRoot "User_AutoBackup_$stamp"
    $fileBackupDir  = Join-Path $AppDataRoot "Migration_FileBackup_$stamp"
    Write-Host "[Backup] Creating User directory backup: $userBackupPath" -ForegroundColor Cyan
    Copy-Item -LiteralPath $UserDir -Destination $userBackupPath -Recurse -Force
    Write-Host "[Backup] Per-file backups (incl. .gemini) will go to: $fileBackupDir" -ForegroundColor Cyan
}

$env:AG_NEW_PATH   = $ResolvedNewPath
$env:AG_OLD_PATH   = $OldFullPath
$env:AG_USER_DIR   = $UserDir
$env:AG_GEMINI_ROOT = $GeminiRoot
$env:AG_APPLY      = if ($Apply) { "1" } else { "0" }
$env:AG_BACKUP_DIR = $fileBackupDir
$env:AG_VERIFY     = if ($Verify) { "1" } else { "0" }
$env:AG_CLEANUP    = if ($Cleanup) { "1" } else { "0" }
$env:AG_INCLUDE_BACKUPS = if ($IncludeBackups) { "1" } else { "0" }
$env:AG_KEEP_DAYS  = "$KeepBackupDays"
$env:PYTHONIOENCODING = "utf-8"

$pyScript = @'
import base64
import ctypes
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import traceback
from pathlib import Path, PureWindowsPath
from urllib.parse import quote, unquote, urlparse

if os.name != "nt":
    sys.exit("This tool supports Windows only.")

NEW_PATH = Path(os.environ["AG_NEW_PATH"]).resolve()
NEW_NAME = NEW_PATH.name
OLD_PATH_ARG = os.environ["AG_OLD_PATH"]
USER_DIR = Path(os.environ["AG_USER_DIR"])
GEMINI_ROOT = Path(os.environ["AG_GEMINI_ROOT"])
APPLY = os.environ["AG_APPLY"] == "1"
VERIFY = os.environ.get("AG_VERIFY") == "1"
CLEANUP = os.environ.get("AG_CLEANUP") == "1"
INCLUDE_BACKUPS = os.environ.get("AG_INCLUDE_BACKUPS") == "1"
KEEP_DAYS = int(os.environ.get("AG_KEEP_DAYS", "7"))
BACKUP_DIR = Path(os.environ["AG_BACKUP_DIR"]) if os.environ.get("AG_BACKUP_DIR") else None

MAX_DEPTH = 8
S = {"changed": 0}

# ---------------------------------------------------------------------------
# Path matching: full OLD path, case-insensitive, any encoding style
# ---------------------------------------------------------------------------
SEP = r"(?:[/\\]+|%(?:25)?(?:2F|5C))"
SUFFIX = r"(?=\Z|[^\w.\-~%]|\.(?![\w\-])|%(?:25)?(?:2F|5C|22|27|29|2C|3B|5D|7D))"


def tolerant(seg: str) -> str:
    """Regex matching a path segment either raw, percent-encoded or double percent-encoded."""
    parts = []
    for ch in seg:
        if ch.isascii() and ch.isalnum():
            parts.append(re.escape(ch))
        else:
            bs = ch.encode("utf-8")
            enc = "".join("%%%02X" % b for b in bs)
            dbl = "".join("%%25%02X" % b for b in bs)
            parts.append("(?:%s|%s|%s)" % (re.escape(ch), enc, dbl))
    return "".join(parts)


def build_path_regex(pw: PureWindowsPath):
    """Compiled regex matching a full Windows path in any textual encoding (groups: parent, leaf)."""
    if not pw.drive or len(pw.parts) < 2:
        raise RuntimeError("Expected an absolute Windows path: %s" % pw)
    segs = list(pw.parts[1:])
    leaf, parent = segs[-1], segs[:-1]
    parent_re = re.escape(pw.drive[0]) + r"(?::|%(?:25)?3A)" + SEP + "".join(tolerant(x) + SEP for x in parent)
    return re.compile(
        r"(?<![A-Za-z0-9])(?P<parent>" + parent_re + r")(?P<leaf>" + tolerant(leaf) + r")" + SUFFIX,
        re.I,
    )


def set_old_path(p) -> None:
    pw = PureWindowsPath(str(p))
    leaf = pw.parts[-1] if len(pw.parts) >= 2 else ""
    S["pattern"] = build_path_regex(pw)
    S["hint"] = re.compile(tolerant(leaf), re.I)
    S["old_leaf"] = leaf
    S["old_path"] = pw
    S["same_parent"] = (
        os.path.normcase(str(pw.parent)) == os.path.normcase(str(PureWindowsPath(str(NEW_PATH)).parent))
    )


def render_parent(parent_text: str) -> str:
    """Render NEW parent directory in the same textual style as the matched OLD parent."""
    p = PureWindowsPath(str(NEW_PATH.parent))
    m0 = re.match(r"([A-Za-z])(:|%(?:25)?3A)", parent_text, re.I)
    letter = p.drive[0].lower() if m0.group(1).islower() else p.drive[0].upper()
    msep = re.search(SEP, parent_text[m0.end():], re.I).group(0)
    segs = list(p.parts[1:])
    if "%" in parent_text:
        segs = [quote(x, safe="") for x in segs]
    return letter + m0.group(2) + msep + "".join(x + msep for x in segs)


def _repl(m):
    parent, leaf = m.group("parent"), m.group("leaf")
    before = m.string[max(0, m.start() - 12):m.start()]
    encode = "%" in parent or "%" in leaf or re.search(r"file:/*$", before, re.I) is not None
    new_leaf = quote(NEW_NAME, safe="") if encode else NEW_NAME
    return (parent if S["same_parent"] else render_parent(parent)) + new_leaf


def apply_path_patterns(s: str) -> str:
    if not S["hint"].search(s):
        return s
    return S["pattern"].sub(_repl, s)


# ---------------------------------------------------------------------------
# Protobuf wire-level rewriting (strict parse, correct length re-encoding, recursive,
# including base64-wrapped sub-messages at any depth)
# ---------------------------------------------------------------------------
class NotMessage(Exception):
    pass


def encode_varint(val: int) -> bytes:
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_varint(buf: bytes, pos: int):
    res, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        res |= (b & 0x7F) << shift
        if not (b & 0x80):
            return res, pos
        shift += 7
        if shift > 63:
            raise NotMessage("varint overflow")
    raise NotMessage("truncated varint")


def parse_fields(buf: bytes):
    if not buf:
        raise NotMessage("empty")
    pos, n, fields = 0, len(buf), []
    while pos < n:
        start = pos
        tag, pos = read_varint(buf, pos)
        fnum, wt = tag >> 3, tag & 7
        if fnum == 0 or fnum > 0x1FFFFFFF:
            raise NotMessage("bad field number")
        tag_bytes = buf[start:pos]
        if wt == 0:
            s2 = pos
            _, pos = read_varint(buf, pos)
            fields.append((tag_bytes, wt, buf[s2:pos]))
        elif wt == 1:
            if pos + 8 > n:
                raise NotMessage("truncated fixed64")
            fields.append((tag_bytes, wt, buf[pos:pos + 8]))
            pos += 8
        elif wt == 5:
            if pos + 4 > n:
                raise NotMessage("truncated fixed32")
            fields.append((tag_bytes, wt, buf[pos:pos + 4]))
            pos += 4
        elif wt == 2:
            length, pos = read_varint(buf, pos)
            if pos + length > n:
                raise NotMessage("truncated length-delimited")
            fields.append((tag_bytes, wt, buf[pos:pos + length]))
            pos += length
        else:
            raise NotMessage("unsupported wire type")
    return fields


def rewrite_message(buf: bytes, depth: int = 0):
    """Return (new_bytes, changed) if buf is a well-formed protobuf message, else None."""
    try:
        fields = parse_fields(buf)
    except NotMessage:
        return None
    out = bytearray()
    changed = False
    for tag_bytes, wt, body in fields:
        out += tag_bytes
        if wt == 2:
            new_body, ch = rewrite_payload(body, depth)
            changed = changed or ch
            out += encode_varint(len(new_body)) + new_body
        else:
            out += body
    return (bytes(out), True) if changed else (buf, False)


CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def decode_text(b: bytes):
    if not b:
        return None
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return None if CTRL_RE.search(s) else s


def rewrite_payload(payload: bytes, depth: int):
    """A length-delimited field: nested message first (strict), then text/JSON/base64 string."""
    if depth >= MAX_DEPTH or len(payload) < 4:
        return payload, False
    r = rewrite_message(payload, depth + 1)
    if r is not None and r[1]:
        return r
    s = decode_text(payload)
    if s is not None:
        new_s, ch = transform_string(s, depth + 1)
        if ch:
            return new_s.encode("utf-8"), True
    return payload, False


# ---------------------------------------------------------------------------
# String / JSON transforms
# ---------------------------------------------------------------------------
B64_RE = re.compile(r"^[A-Za-z0-9+/_-]{16,}={0,2}$")


def transform_json_node(node, depth: int = 0):
    if isinstance(node, dict):
        changed = False
        new_dict = {}
        key_changed_values = []
        for k, v in node.items():
            nk, kc = transform_string(k, depth) if isinstance(k, str) else (k, False)
            nv, vc = transform_json_node(v, depth)
            if kc and S.get("lower_keys"):
                nk = nk.lower()  # ~/.gemini/projects.json stores lower-cased paths and names
            # projects.json style map: {"<old path>": "<old leaf name>"}
            if kc and isinstance(v, str) and v.strip().lower() == S["old_leaf"].lower():
                nv, vc = (NEW_NAME.lower() if S.get("lower_keys") else NEW_NAME), True
            new_dict[nk] = nv
            changed = changed or kc or vc
            if k == "projectResources" and (kc or vc):
                key_changed_values.append(True)
        # Antigravity project file: bare display name equal to the old folder name
        if key_changed_values and isinstance(new_dict.get("name"), str) \
                and new_dict["name"].strip().lower() == S["old_leaf"].lower():
            new_dict["name"] = NEW_NAME
            changed = True
        return new_dict, changed
    if isinstance(node, list):
        changed = False
        new_list = []
        for item in node:
            ni, ic = transform_json_node(item, depth)
            new_list.append(ni)
            changed = changed or ic
        return new_list, changed
    if isinstance(node, str):
        return transform_string(node, depth)
    return node, False


def decode_b64(s: str):
    is_url = "-" in s or "_" in s
    if is_url and ("+" in s or "/" in s):
        return None
    body = s.rstrip("=")
    padded = body + "=" * ((4 - len(body) % 4) % 4)
    try:
        return base64.urlsafe_b64decode(padded) if is_url else base64.b64decode(padded), is_url
    except Exception:
        return None


def transform_string(s: str, depth: int = 0):
    if len(s) < 8:
        return s, False

    if s.lstrip()[:1] in ("{", "["):
        try:
            parsed = json.loads(s)
        except ValueError:
            parsed = None
        if isinstance(parsed, (dict, list)):
            new_parsed, changed = transform_json_node(parsed, depth)
            if not changed:
                return s, False
            candidate = apply_path_patterns(s)  # keeps original formatting when equivalent
            try:
                if candidate != s and json.loads(candidate) == new_parsed:
                    return candidate, True
            except ValueError:
                pass
            return json.dumps(new_parsed, ensure_ascii=False, separators=(",", ":")), True

    updated = apply_path_patterns(s)
    if updated != s:
        return updated, True

    if depth < MAX_DEPTH and B64_RE.match(s):
        dec = decode_b64(s)
        if dec is not None:
            raw, is_url = dec
            r = rewrite_message(raw, depth + 1)
            if r is not None and r[1]:
                enc = base64.urlsafe_b64encode(r[0]) if is_url else base64.b64encode(r[0])
                res = enc.decode("ascii")
                if len(s) % 4 != 0:
                    res = res.rstrip("=")
                return res, True
    return s, False


def transform_blob(b: bytes):
    """Return new bytes, or None when unchanged."""
    r = rewrite_message(b)
    if r is not None:
        return r[0] if r[1] else None
    s = decode_text(b)
    if s is not None:
        new_s, ch = transform_string(s)
        if ch:
            return new_s.encode("utf-8")
    return None


# ---------------------------------------------------------------------------
# VS Code workspace identity helpers
# ---------------------------------------------------------------------------
def get_birthtime_ms(target: Path) -> int:
    """Integer ms, identical to VS Code on Windows: Math.floor(stat.birthtimeMs)."""
    class FILETIME(ctypes.Structure):
        _fields_ = [("dwLowDateTime", ctypes.c_uint32), ("dwHighDateTime", ctypes.c_uint32)]

    class WIN32_FILE_ATTRIBUTE_DATA(ctypes.Structure):
        _fields_ = [
            ("dwFileAttributes", ctypes.c_uint32),
            ("ftCreationTime", FILETIME),
            ("ftLastAccessTime", FILETIME),
            ("ftLastWriteTime", FILETIME),
            ("nFileSizeHigh", ctypes.c_uint32),
            ("nFileSizeLow", ctypes.c_uint32),
        ]

    data = WIN32_FILE_ATTRIBUTE_DATA()
    if ctypes.windll.kernel32.GetFileAttributesExW(str(target), 0, ctypes.byref(data)):
        ft = (data.ftCreationTime.dwHighDateTime << 32) | data.ftCreationTime.dwLowDateTime
        return (ft - 116444736000000000) // 10000
    st = os.stat(target)
    return getattr(st, "st_birthtime_ns", st.st_ctime_ns) // 1_000_000


def workspace_hash(folder: Path) -> str:
    fs_path = str(folder)
    if len(fs_path) >= 2 and fs_path[1] == ":":
        fs_path = fs_path[0].lower() + fs_path[1:]
    return hashlib.md5((fs_path + str(get_birthtime_ms(folder))).encode("utf-8")).hexdigest()


def vscode_uri(p: Path) -> str:
    s = str(p)
    return "file:///" + s[0].lower() + "%3A" + quote(s[2:].replace("\\", "/"), safe="/")


def uri_to_path(uri: str):
    if not uri:
        return None
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    raw = unquote(parsed.path)
    if len(raw) >= 3 and raw[0] == "/" and raw[2] == ":":
        raw = raw[1:]
    return raw


def newest(paths):
    def key(d):
        f = d / "state.vscdb"
        return (f if f.exists() else d).stat().st_mtime
    return max(paths, key=key)


# ---------------------------------------------------------------------------
# Transaction: per-file backups + rollback
# ---------------------------------------------------------------------------
class Tx:
    def __init__(self):
        self.entries = []   # (orig, backup)
        self.created = []
        self.n = 0

    def _log(self, obj):
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        with open(BACKUP_DIR / "manifest.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj) + "\n")

    def _dest(self, path: Path) -> Path:
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        self.n += 1
        return BACKUP_DIR / ("%05d_%s" % (self.n, path.name))

    def backup_file(self, path: Path):
        if not APPLY or BACKUP_DIR is None or not path.exists():
            return
        dest = self._dest(path)
        shutil.copy2(path, dest)
        self.entries.append((path, dest))
        self._log({"orig": str(path), "backup": str(dest)})

    def backup_sqlite(self, conn, path: Path):
        dest = self._dest(path)
        dst = sqlite3.connect(dest)
        try:
            conn.backup(dst)
        finally:
            dst.close()
        self.entries.append((path, dest))
        self._log({"orig": str(path), "backup": str(dest)})

    def track_created(self, path: Path):
        if APPLY and not path.exists():
            self.created.append(path)
            if BACKUP_DIR is not None:
                self._log({"created": str(path)})

    def rollback(self):
        for orig, bak in reversed(self.entries):
            try:
                for ext in ("-wal", "-shm", "-journal"):
                    p = Path(str(orig) + ext)
                    if p.exists():
                        p.unlink()
                shutil.copy2(bak, orig)
            except Exception as exc:
                print("  rollback failed for %s: %r (backup: %s)" % (orig, exc, bak))
        for p in reversed(self.created):
            try:
                if p.is_dir():
                    shutil.rmtree(p)
                elif p.exists():
                    p.unlink()
            except Exception as exc:
                print("  could not remove %s: %r" % (p, exc))


def log(tag: str, msg: str):
    S["changed"] += 1
    print(("[%s]" % tag).ljust(12) + msg)


# ---------------------------------------------------------------------------
# File processors
# ---------------------------------------------------------------------------
def detect_indent(text: str):
    m = re.search(r"\n([ \t]+)\S", text)
    return m.group(1) if m else None


def process_text_file(path: Path, kind: str, tx: Tx, tag: str, shown: str, backup: bool = True) -> bool:
    try:
        raw = path.read_bytes()
    except OSError:
        return False
    bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        text = (raw[3:] if bom else raw).decode("utf-8")
    except UnicodeDecodeError:
        return False
    if not S["hint"].search(text) and kind != "json":
        return False
    out = None
    if kind == "json":
        try:
            parsed = json.loads(text)
        except ValueError:
            kind = "text"
        else:
            S["lower_keys"] = path.name.lower() == "projects.json" and path.parent == GEMINI_ROOT
            try:
                new_parsed, changed = transform_json_node(parsed)
            finally:
                S["lower_keys"] = False
            if not changed:
                return False
            candidate = apply_path_patterns(text)
            try:
                same = candidate != text and json.loads(candidate) == new_parsed
            except ValueError:
                same = False
            if same:
                out = candidate
            else:
                indent = detect_indent(text)
                if indent is None:
                    out = json.dumps(new_parsed, ensure_ascii=False, separators=(",", ":"))
                else:
                    out = json.dumps(new_parsed, ensure_ascii=False, indent=indent)
                if text.endswith("\n"):
                    out += "\n"
    if kind == "text":
        out = apply_path_patterns(text)
        if out == text:
            return False
    log(tag, shown)
    if APPLY:
        if backup:
            tx.backup_file(path)
        path.write_bytes((b"\xef\xbb\xbf" if bom else b"") + out.encode("utf-8"))
    return True


def process_pb_file(path: Path, tx: Tx, shown: str):
    try:
        raw = path.read_bytes()
    except OSError:
        return
    r = rewrite_message(raw)
    if r is not None and r[1]:
        log("Protobuf", shown)
        if APPLY:
            tx.backup_file(path)
            path.write_bytes(r[0])


SKIP_TABLE = re.compile(r"(^sqlite_)|(_fts(_|$))", re.I)


def convert_value(val):
    if isinstance(val, str):
        if len(val) < 8:
            return None
        new, ch = transform_string(val)
        if ch:
            try:
                new.encode("utf-8")
            except UnicodeEncodeError:
                return None
            return new
    elif isinstance(val, (bytes, bytearray)):
        if len(val) < 8:
            return None
        return transform_blob(bytes(val))
    return None


def process_sqlite(db_path: Path, tx: Tx, shown: str):
    if not db_path.is_file():
        return
    changes = []
    try:
        conn = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True)
    except sqlite3.Error as exc:
        print("[SQLite]    skipped %s (%s)" % (shown, exc))
        return
    try:
        conn.text_factory = lambda b: b.decode("utf-8", "surrogateescape")
        try:
            tables = conn.execute("SELECT name, sql FROM sqlite_master WHERE type='table'").fetchall()
        except sqlite3.Error as exc:
            print("[SQLite]    skipped %s (%s)" % (shown, exc))
            return
        for tname, tsql in tables:
            up = (tsql or "").upper()
            if SKIP_TABLE.search(tname) or "VIRTUAL TABLE" in up or "WITHOUT ROWID" in up:
                continue
            try:
                cols = [r[1] for r in conn.execute('PRAGMA table_info("%s")' % tname)]
                keycol = cols.index("key") if "key" in cols else None
                for row in conn.execute('SELECT rowid, * FROM "%s"' % tname):
                    for i, val in enumerate(row[1:]):
                        new = convert_value(val)
                        if new is not None:
                            ident = row[1 + keycol] if keycol is not None else "rowid=%s" % row[0]
                            changes.append((tname, cols[i], row[0], new, ident))
            except sqlite3.Error as exc:
                print("[SQLite]    skipped table %s in %s (%s)" % (tname, shown, exc))
        for tname, col, _, _, ident in changes:
            log("SQLite", "%s -> %s.%s [%s]" % (shown, tname, col, str(ident)[:80]))
        if not (APPLY and changes):
            return
        pre = conn.execute("PRAGMA integrity_check;").fetchone()[0]
        if pre != "ok":
            raise RuntimeError("SQLite integrity check failed before update on %s: %s" % (db_path, pre))
        if BACKUP_DIR is not None:
            tx.backup_sqlite(conn, db_path)
    finally:
        conn.close()

    rw = sqlite3.connect(db_path)
    try:
        rw.execute("BEGIN IMMEDIATE;")
        for tname, col, rowid, new, _ in changes:
            rw.execute('UPDATE "%s" SET "%s" = ? WHERE rowid = ?' % (tname, col), (new, rowid))
        rw.commit()
        post = rw.execute("PRAGMA integrity_check;").fetchone()[0]
        if post != "ok":
            raise RuntimeError("SQLite integrity check failed after update on %s: %s" % (db_path, post))
        try:
            rw.execute("PRAGMA wal_checkpoint(TRUNCATE);").fetchall()
        except sqlite3.Error:
            pass
    finally:
        rw.close()

    if db_path.name == "state.vscdb":
        bak = db_path.with_name("state.vscdb.backup")
        if bak.exists():
            tx.backup_file(bak)
            shutil.copy2(db_path, bak)


def copy_tree_tracked(src: Path, dst: Path, tx: Tx, skip=("workspace.json",)):
    for item in src.iterdir():
        if item.name in skip:
            continue
        target = dst / item.name
        if item.is_dir():
            if not target.exists():
                tx.track_created(target)
                target.mkdir(parents=True)
            copy_tree_tracked(item, target, tx, ())
        else:
            if target.exists():
                tx.backup_file(target)
            else:
                tx.track_created(target)
            shutil.copy2(item, target)


SKIP_DIRS = {".system_generated", "browser_recordings", "tempmediastorage", "node_modules", ".git",
             "cache", "log", "logs", "bin", "builtin", "plugins", "plugin_data", "crashes"}


def scan_gemini(tx: Tx):
    targets = [
        GEMINI_ROOT / "antigravity",
        GEMINI_ROOT / "antigravity-ide",
        GEMINI_ROOT / "config" / "projects",
        GEMINI_ROOT / "projects.json",
    ]

    def handle(path: Path):
        suffix = path.suffix.lower()
        try:
            size = path.stat().st_size
        except OSError:
            return
        shown = ".gemini/" + path.relative_to(GEMINI_ROOT).as_posix()
        if suffix == ".db":
            process_sqlite(path, tx, shown)
        elif size > 50 * 1024 * 1024:
            return
        elif suffix == ".pb":
            process_pb_file(path, tx, shown)
        elif size > 10 * 1024 * 1024:
            return
        elif suffix == ".json":
            process_text_file(path, "json", tx, "Project" if "projects" in path.parts else "Metadata", shown)
        elif suffix in (".md", ".txt", ".pbtxt"):
            process_text_file(path, "text", tx, "Metadata", shown)

    for t in targets:
        if t.is_file():
            handle(t)
        elif t.is_dir():
            for dp, dn, fn in os.walk(t):
                dn[:] = [d for d in dn if d.lower() not in SKIP_DIRS]
                for f in fn:
                    handle(Path(dp) / f)


# ---------------------------------------------------------------------------
# Verification (read-only): proves the migration took effect
# ---------------------------------------------------------------------------
def collect_leaves(buf: bytes, via_b64: bool = False, depth: int = 0):
    """Text leaves of a protobuf as (found_inside_base64, text); None if buf is not a valid message."""
    try:
        fields = parse_fields(buf)
    except NotMessage:
        return None
    out = []
    for _, wt, body in fields:
        if wt != 2:
            continue
        if depth < MAX_DEPTH:
            sub = collect_leaves(body, via_b64, depth + 1)
            if sub is not None:
                out += sub
                continue
        s = decode_text(body)
        if s is None:
            continue
        if B64_RE.match(s):
            dec = decode_b64(s)
            if dec is not None:
                sub = collect_leaves(dec[0], True, depth + 1)
                if sub is not None:
                    out += sub
                    continue
        out.append((via_b64, s))
    return out


def read_item(db_path: Path, key: str):
    try:
        conn = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True)
        try:
            conn.text_factory = lambda b: b.decode("utf-8", "surrogateescape")
            row = conn.execute("SELECT value FROM ItemTable WHERE key = ?", (key,)).fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        return None
    if row is None:
        return None
    v = row[0]
    return v.decode("utf-8", "ignore") if isinstance(v, (bytes, bytearray)) else v


def db_health(db_path: Path):
    try:
        conn = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True)
        try:
            ok = conn.execute("PRAGMA integrity_check;").fetchone()[0]
            n = conn.execute("SELECT COUNT(*) FROM ItemTable").fetchone()[0]
        finally:
            conn.close()
        return ok, n
    except sqlite3.Error as exc:
        return str(exc), 0


def capture(fn, *args):
    """Run a (dry-run) processor and return the '[Tag] ...' lines it printed."""
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(*args)
    return [ln for ln in buf.getvalue().splitlines() if ln.startswith("[")]


def verify() -> int:
    res = []

    def add(status, title, detail=""):
        res.append((status, title, detail))

    tx = Tx()
    expected_new = os.path.normcase(os.path.normpath(str(NEW_PATH)))
    expected_old = os.path.normcase(os.path.normpath(str(S["old_path"])))
    new_pat = build_path_regex(PureWindowsPath(str(NEW_PATH)))
    old_pat = S["pattern"]
    ws_root = USER_DIR / "workspaceStorage"
    expected_hash = workspace_hash(NEW_PATH)
    new_dirs, old_dirs = [], []
    if ws_root.is_dir():
        for d in ws_root.iterdir():
            try:
                raw = uri_to_path(json.loads((d / "workspace.json").read_text(encoding="utf-8-sig")).get("folder", ""))
            except Exception:
                continue
            if raw is None:
                continue
            norm = os.path.normcase(os.path.normpath(raw))
            if norm == expected_new:
                new_dirs.append(d)
            elif norm == expected_old:
                old_dirs.append(d)

    # 1. workspace identity ------------------------------------------------
    exp_dir = ws_root / expected_hash
    if exp_dir.is_dir():
        add("PASS", "Workspace storage exists under the hash the IDE computes for the new folder", expected_hash)
        try:
            folder = json.loads((exp_dir / "workspace.json").read_text(encoding="utf-8-sig")).get("folder")
        except Exception:
            folder = None
        if folder == vscode_uri(NEW_PATH):
            add("PASS", "workspace.json points to the new folder (canonical URI)")
        elif folder and os.path.normcase(os.path.normpath(uri_to_path(folder) or "")) == expected_new:
            add("WARN", "workspace.json points to the new folder but in a non-canonical form", folder)
        else:
            add("FAIL", "workspace.json does not point to the new folder", str(folder))
    elif new_dirs:
        add("FAIL", "Workspace is registered under a hash the IDE will NOT use for this folder",
            "found: %s | expected: %s" % (", ".join(d.name for d in new_dirs), expected_hash))
    else:
        add("FAIL", "No workspaceStorage entry for the new folder",
            "expected %s - run the migration (or open the folder once, then migrate)" % expected_hash)
    stale = [d.name for d in new_dirs if d.name != expected_hash]
    if stale and exp_dir.is_dir():
        add("INFO", "Extra workspace entries point at the same folder (harmless leftovers)", ", ".join(stale))

    # 2. workspace state ---------------------------------------------------
    ws_db = exp_dir / "state.vscdb"
    if ws_db.is_file():
        ok, n = db_health(ws_db)
        add("PASS" if ok == "ok" else "FAIL", "Workspace state database is healthy (%d entries)" % n,
            "" if ok == "ok" else ok)
        lines = capture(process_sqlite, ws_db, tx, "workspaceStorage/%s/state.vscdb" % exp_dir.name)
        if lines:
            add("FAIL", "Workspace state still references the OLD path", "; ".join(l.split("->")[-1].strip() for l in lines[:5]))
        else:
            add("PASS", "Workspace state contains no references to the old path")
    elif exp_dir.is_dir():
        add("WARN", "Workspace state database missing (editor layout/history was not carried over)")

    # 3. global state ------------------------------------------------------
    gdb = USER_DIR / "globalStorage" / "state.vscdb"
    if gdb.is_file():
        ok, n = db_health(gdb)
        add("PASS" if ok == "ok" else "FAIL", "Global state database is healthy (%d entries)" % n, "" if ok == "ok" else ok)
        lines = capture(process_sqlite, gdb, tx, "globalStorage/state.vscdb")
        if lines:
            add("FAIL", "Global state still references the OLD path", "; ".join(l.split("->")[-1].strip() for l in lines[:5]))
        else:
            add("PASS", "Global state contains no references to the old path")
        recent = read_item(gdb, "history.recentlyOpenedPathsList")
        if recent and new_pat.search(recent):
            add("PASS", "New folder is in the recently-opened list")
        else:
            add("WARN", "New folder is not in the recently-opened list", "it is added when the folder is opened once")
        sidebar = read_item(gdb, "antigravityUnifiedStateSync.sidebarWorkspaces")
        if sidebar:
            dec = decode_b64(sidebar.strip())
            leaves = collect_leaves(dec[0]) if dec else None
            if leaves is None:
                add("FAIL", "Sidebar workspace list is not valid protobuf (corrupted)")
            else:
                plain = sum(1 for b, s in leaves if not b and new_pat.search(s))
                nested = sum(1 for b, s in leaves if b and new_pat.search(s))
                if plain and nested:
                    add("PASS", "Sidebar workspace list is valid and lists the new folder consistently",
                        "%d plain + %d nested entries" % (plain, nested))
                elif plain or nested:
                    add("FAIL", "Sidebar workspace list is inconsistent",
                        "plain=%d nested(base64)=%d - one copy of the URI was not updated" % (plain, nested))
                else:
                    add("WARN", "New folder is not in the sidebar workspace list", "it is added when the folder is opened once")
    else:
        add("FAIL", "Global state database not found", str(gdb))

    lines = capture(process_text_file, USER_DIR / "globalStorage" / "storage.json", "json", tx, "JSON", "globalStorage/storage.json")
    lines += capture(process_text_file, USER_DIR.parent / "Backups" / "workspaces.json", "json", tx, "JSON", "Backups/workspaces.json")
    if lines:
        add("FAIL", "storage.json / Backups still reference the OLD path", "; ".join(l.split("]", 1)[1].strip() for l in lines))
    else:
        add("PASS", "storage.json and hot-exit Backups contain no references to the old path")

    # 4. Antigravity 2.0 projects -----------------------------------------
    matches = []
    pdir = GEMINI_ROOT / "config" / "projects"
    if pdir.is_dir():
        for f in sorted(pdir.glob("*.json")):
            try:
                text = f.read_text(encoding="utf-8-sig")
                data = json.loads(text)
            except Exception:
                continue
            uris = []

            def walk(n):
                if isinstance(n, dict):
                    for k, v in n.items():
                        if k == "folderUri" and isinstance(v, str):
                            uris.append(v)
                        else:
                            walk(v)
                elif isinstance(n, list):
                    for i in n:
                        walk(i)
            walk(data.get("projectResources", {}))
            if any(new_pat.search(u) for u in uris):
                matches.append((f.name, data.get("name")))
    if len(matches) == 1:
        add("PASS", "An Antigravity project is linked to the new folder", "%s (name: %s)" % matches[0])
    elif len(matches) > 1:
        add("WARN", "Several Antigravity projects are linked to the new folder", ", ".join(m[0] for m in matches))
    else:
        add("WARN", "No Antigravity 2.0 project is linked to the new folder yet",
            "the old project (and its conversations) was not found/migrated, or the folder was never added as a project")

    # 5. .gemini scan (agent app + IDE) ------------------------------------
    lines = capture(scan_gemini, tx)
    proj = [l for l in lines if "config/projects" in l or l.endswith("projects.json")]
    link = [l for l in lines if l not in proj and (".pb" in l or "agyhub" in l or "antigravity_state" in l)]
    conv = [l for l in lines if l not in proj and l not in link]
    if proj:
        add("FAIL", "Project files still reference the OLD path", "; ".join(l.split("]", 1)[1].strip() for l in proj[:5]))
    else:
        add("PASS", "Project files (config/projects, projects.json) contain no references to the old path")
    if link:
        add("FAIL", "Workspace summary/index files still reference the OLD path", "; ".join(l.split("]", 1)[1].strip() for l in link[:5]))
    else:
        add("PASS", "Workspace summary/index files contain no references to the old path")
    if conv:
        add("WARN", "%d conversation/metadata entries still mention the old path" % len(conv),
            "may be later chat text that merely quotes the old path; list: " + "; ".join(l.split("]", 1)[1].strip() for l in conv[:3]))
    else:
        add("PASS", "Conversation databases and metadata contain no references to the old path")

    # 6. leftovers ---------------------------------------------------------
    S["verify_info"] = {"exp_dir": exp_dir, "old_dirs": old_dirs,
                        "stale": [d for d in new_dirs if d.name != expected_hash]}
    if old_dirs:
        add("INFO", "Old workspace entry still on disk (kept as a safety copy)",
            ", ".join(d.name for d in old_dirs) + " - safe to delete once you are satisfied")
    if os.path.exists(str(S["old_path"])) and expected_old != expected_new:
        add("WARN", "A folder still exists at the old path", str(S["old_path"]))

    # report -------------------------------------------------------------
    print("\n===== Verification report =====")
    print("New folder : %s" % NEW_PATH)
    print("Old folder : %s" % S["old_path"])
    for st, title, detail in res:
        print("[%s] %s" % (st, title))
        if detail:
            print("        %s" % detail)
    fails = sum(1 for r in res if r[0] == "FAIL")
    warns = sum(1 for r in res if r[0] == "WARN")
    if fails:
        verdict = "NOT VERIFIED - %d check(s) failed. Re-run with -Apply (Antigravity closed), then -Verify again." % fails
    elif warns:
        verdict = "VERIFIED with %d warning(s) - the workspace link is intact; warnings are informational." % warns
    else:
        verdict = "VERIFIED - all checks passed."
    print("\nVerdict: " + verdict)
    if not fails and not CLEANUP and (S["verify_info"]["old_dirs"] or S["verify_info"]["stale"]):
        print("Tip: leftovers can be removed with -Cleanup (preview) / -Cleanup -Apply (delete).")
    return 2 if fails else 0


# ---------------------------------------------------------------------------
# Leftover cleanup (only after a clean verification)
# ---------------------------------------------------------------------------
HASH_RE = re.compile(r"^[0-9a-f]{32}$")


def dir_size(p: Path) -> int:
    total = 0
    for dp, _, fn in os.walk(p):
        for f in fn:
            try:
                total += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return total


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def _force_remove(func, path, _exc):
    import stat
    os.chmod(path, stat.S_IWRITE)
    func(path)


def cleanup(do_delete: bool) -> int:
    from datetime import datetime, timedelta
    info = S["verify_info"]
    exp_dir = info["exp_dir"]
    ws_root = USER_DIR / "workspaceStorage"
    app_root = USER_DIR.parent
    backups_root = app_root / "Backups"
    items = []   # (path, reason, allowed_parent, name_regex)

    for d in info["old_dirs"]:
        items.append((d, "old workspace entry (its state was migrated)", ws_root, HASH_RE))
    for d in info["stale"]:
        items.append((d, "stale duplicate workspace entry for the new folder", ws_root, HASH_RE))
    skipped = []
    for d, *_ in list(items):
        b = backups_root / d.name
        if b.is_dir():
            if (backups_root / exp_dir.name).is_dir():
                items.append((b, "hot-exit backup of the removed workspace entry (migrated copy exists)", backups_root, HASH_RE))
            else:
                skipped.append("Backups/%s kept: it holds unsaved-file backups that were not migrated" % d.name)

    if INCLUDE_BACKUPS:
        cutoff = datetime.now() - timedelta(days=KEEP_DAYS)
        specs = [(app_root, re.compile(r"^(User_AutoBackup|Migration_FileBackup)_(\d{8}_\d{6})$")),
                 (GEMINI_ROOT, re.compile(r"^(antigravity_AutoBackup)_(\d{8}_\d{6})$"))]
        for root, rx in specs:
            if not root.is_dir():
                continue
            kinds = {}
            for d in root.iterdir():
                m = rx.match(d.name)
                if m and d.is_dir():
                    try:
                        kinds.setdefault(m.group(1), []).append((datetime.strptime(m.group(2), "%Y%m%d_%H%M%S"), d))
                    except ValueError:
                        pass
            for kind, lst in kinds.items():
                lst.sort(key=lambda t: t[0])
                newest_dir = lst[-1][1]
                for dt, d in lst:
                    if d == newest_dir:
                        skipped.append("%s kept: newest %s" % (d.name, kind))
                    elif dt < cutoff:
                        items.append((d, "%s older than %d days" % (kind, KEEP_DAYS), root, rx))
                    else:
                        skipped.append("%s kept: newer than %d days" % (d.name, KEEP_DAYS))

    print("\n===== Leftover cleanup (%s) =====" % ("DELETING" if do_delete else "preview - nothing is deleted"))
    for s in skipped:
        print("[KEEP]   " + s)
    if not items:
        print("Nothing to clean up.")
        return 0

    total, freed, failed = 0, 0, 0
    for path, reason, parent, rx in items:
        # Safety rails: exact expected parent, expected name shape, never the live workspace entry
        same_parent = os.path.normcase(os.path.normpath(str(path.parent))) == os.path.normcase(os.path.normpath(str(parent)))
        if not (same_parent and rx.match(path.name) and path != exp_dir and path.is_dir() and not path.is_symlink()):
            print("[SKIP]   %s (failed safety check)" % path)
            continue
        size = dir_size(path)
        total += size
        if not do_delete:
            print("[DELETE] %s  (%s) - %s" % (path, human(size), reason))
            continue
        try:
            shutil.rmtree(path, onerror=_force_remove)
            freed += size
            print("[DELETED] %s  (%s) - %s" % (path, human(size), reason))
        except Exception as exc:
            failed += 1
            print("[FAILED] %s: %r" % (path, exc))
    if do_delete:
        print("\nFreed %s%s." % (human(freed), "; %d item(s) could not be removed" % failed if failed else ""))
    else:
        print("\nWould free %s. Re-run with -Cleanup -Apply (Antigravity closed) to delete." % human(total))
    return 1 if failed else 0


# ===== MAIN =====
def run(tx: Tx):
    old_path_ntcase = lambda: os.path.normcase(os.path.normpath(str(S["old_path"])))
    expected_new = os.path.normcase(os.path.normpath(str(NEW_PATH)))
    ws_root = USER_DIR / "workspaceStorage"

    # Step 1: locate old / new workspaceStorage hash folders
    exact_old, new_cands, loose = [], [], []
    expected_old = old_path_ntcase()
    if ws_root.is_dir():
        for d in ws_root.iterdir():
            wj = d / "workspace.json"
            if not (d.is_dir() and wj.is_file()):
                continue
            try:
                data = json.loads(wj.read_text(encoding="utf-8-sig"))
            except Exception:
                continue
            raw = uri_to_path(data.get("folder", ""))
            if raw is None:
                continue
            norm = os.path.normcase(os.path.normpath(raw))
            if norm == expected_old:
                exact_old.append(d)
            if norm == expected_new and expected_new != expected_old:
                new_cands.append(d)
            elif norm not in (expected_old, expected_new) \
                    and Path(raw).name.lower() == S["old_leaf"].lower() and not os.path.exists(raw):
                loose.append((d, raw))

    old_ws_dir = None
    if exact_old:
        old_ws_dir = newest(exact_old)
    elif len(loose) == 1:
        old_ws_dir, raw = loose[0]
        print("[Workspace] Old path not found verbatim; using the only vanished workspace named "
              "'%s': %s" % (S["old_leaf"], raw))
        set_old_path(raw)
    elif len(loose) > 1:
        raise RuntimeError("Multiple vanished workspaceStorage folders match '%s' (%s); pass the full old path "
                           "as -OldFolderName." % (S["old_leaf"], ", ".join(d.name for d, _ in loose)))

    expected_hash = workspace_hash(NEW_PATH)
    new_ws_dir = None
    if (ws_root / expected_hash).is_dir():
        new_ws_dir = ws_root / expected_hash
    # Entries for the new folder under any OTHER hash are never used by the IDE (leftovers of
    # older runs); the state always goes to the hash the IDE computes. -Cleanup removes the leftovers.
    others = [d.name for d in new_cands if d.name != expected_hash]
    if others:
        print("[Workspace] Ignoring entries for the new folder under unused hashes: %s" % ", ".join(others))

    if old_ws_dir:
        print("[Workspace] Source hash folder : %s" % old_ws_dir.name)
        new_ws_creating = new_ws_dir is None
        if new_ws_creating:
            new_ws_dir = ws_root / expected_hash
            print("[Workspace] Created target hash: %s" % new_ws_dir.name)
        else:
            print("[Workspace] Target hash folder : %s" % new_ws_dir.name)
        if APPLY:
            if not new_ws_dir.exists():
                tx.track_created(new_ws_dir)
                new_ws_dir.mkdir(parents=True)
            wj = new_ws_dir / "workspace.json"
            if not wj.exists():
                tx.track_created(wj)
                with open(wj, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(json.dumps({"folder": vscode_uri(NEW_PATH)}, indent=2))
        if old_ws_dir != new_ws_dir:
            print("[Workspace] Copy state & extensions: %s -> %s (preserving workspace.json)"
                  % (old_ws_dir.name, new_ws_dir.name))
            if APPLY:
                copy_tree_tracked(old_ws_dir, new_ws_dir, tx)

        backups_root = USER_DIR.parent / "Backups"
        old_bak, new_bak = backups_root / old_ws_dir.name, backups_root / new_ws_dir.name
        if old_bak.exists() and not new_bak.exists():
            print("[Backups]   Migrate hot-exit folder: %s -> %s" % (old_bak.name, new_bak.name))
            if APPLY:
                tx.track_created(new_bak)
                shutil.copytree(old_bak, new_bak)
                for meta in new_bak.rglob("meta.json"):
                    process_text_file(meta, "json", tx, "Backups", "Backups/%s" % meta.relative_to(backups_root).as_posix(),
                                      backup=False)
    else:
        print("[Workspace] No source workspaceStorage folder matched '%s'." % S["old_leaf"])

    # Step 2: SQLite state (global + the migrated workspace)
    process_sqlite(USER_DIR / "globalStorage" / "state.vscdb", tx, "globalStorage/state.vscdb")
    candidates = [new_ws_dir, old_ws_dir] if APPLY else [old_ws_dir, new_ws_dir]
    ws_db_dir = next((c for c in candidates if c), None)
    if ws_db_dir:
        process_sqlite(ws_db_dir / "state.vscdb", tx, "workspaceStorage/%s/state.vscdb" % ws_db_dir.name)

    # Step 3: JSON state
    process_text_file(USER_DIR / "globalStorage" / "storage.json", "json", tx, "JSON", "globalStorage/storage.json")
    process_text_file(USER_DIR.parent / "Backups" / "workspaces.json", "json", tx, "JSON", "Backups/workspaces.json")

    # Step 4: .gemini (agent app + IDE + 2.0 projects)
    scan_gemini(tx)

    print("\nItems %s: %d" % ("updated" if APPLY else "to update", S["changed"]))
    print("Status:", "APPLIED SUCCESSFULLY" if APPLY else "DRY RUN COMPLETE (re-run with -Apply to commit changes)")


def main():
    # Expand 8.3 short names in the parent so old and new paths use the same spelling as the stored URIs.
    _old = Path(OLD_PATH_ARG)
    set_old_path(Path(os.path.realpath(_old.parent)) / _old.name)
    global APPLY
    if CLEANUP:
        do_delete = APPLY
        APPLY = False  # the verification gate is strictly read-only
        code = verify()
        if code:
            print("\nCleanup refused: fix the failed checks first (nothing was deleted).")
            sys.exit(code)
        sys.exit(cleanup(do_delete))
    if VERIFY:
        APPLY = False
        sys.exit(verify())
    tx = Tx()
    try:
        run(tx)
        if APPLY:
            APPLY = False  # post-apply verification is strictly read-only
            code = verify()
            if code:
                sys.exit(code)
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc(file=sys.stdout)
        if APPLY:
            print("Rolling back all modified files ...")
            tx.rollback()
            print("[Rollback] Original state restored.")
        sys.exit(1)


if __name__ == "__main__":
    main()
'@

# Write Python script as UTF-8 without BOM to avoid PowerShell pipeline encoding issues
$tempPy = Join-Path ([System.IO.Path]::GetTempPath()) ("ag_migrate_" + [System.Guid]::NewGuid().ToString("N") + ".py")
try {
    [System.IO.File]::WriteAllText($tempPy, $pyScript, [System.Text.UTF8Encoding]::new($false))
    & $pythonExe @pythonArgs $tempPy
    $pyExit = $LASTEXITCODE
    if ($pyExit -eq 2) {
        # Verification report ran and reported failed checks (the report was already printed).
        exit 2
    }
    if ($pyExit -ne 0) {
        throw "Python migration engine exited with code $pyExit."
    }
} catch {
    Write-Warning "Migration encountered an error: $_"
    if ($Apply) {
        Write-Warning "The engine restores every file it modified. Safety copies: $userBackupPath and $fileBackupDir"
    }
    exit 1
} finally {
    if (Test-Path -LiteralPath $tempPy) {
        Remove-Item -LiteralPath $tempPy -Force -ErrorAction SilentlyContinue
    }
}
