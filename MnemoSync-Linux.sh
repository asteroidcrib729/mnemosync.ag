#!/usr/bin/env bash
# Preserves Antigravity workspaces / projects on Linux after a project root directory rename/move.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  MnemoSync-Linux.sh --new-project-path <path> --old-folder-name <name|path> [options]
  MnemoSync-Linux.sh --list-backups [--app-data-folder-name <name>]
  MnemoSync-Linux.sh --restore --backup-stamp <yyyyMMdd_HHmmss> [--apply] [--app-data-folder-name <name>]

Options:
  --new-project-path <path>        Target project directory (already renamed, or destination with --rename-on-disk)
  --old-folder-name <name|path>    Old folder leaf name or full old path
  --app-data-folder-name <name>    Folder under ~/.config (or $XDG_CONFIG_HOME) [default: "Antigravity IDE"]
  --apply                          Commit changes (migration, cleanup, or restore). Without it, runs dry-run/preview
  --verify                         Read-only verification checklist (exit 0 if verified, 2 if checks fail)
  --cleanup                        Remove verified leftover workspaceStorage/Backups/History folders (preview by default)
  --include-backups                With --cleanup: also prune aged script backups older than --keep-backup-days
  --keep-backup-days <days>        Age threshold in days for --include-backups (0-3650, default: 7)
  --overwrite-existing-state       Force copying old workspaceStorage state over a newer populated target state.vscdb
  --rename-on-disk                 Rename/move OldFolderName -> NewProjectPath on disk, then migrate metadata
  --list-backups                   List available migration backup timestamps and exit
  --restore                        Restore a prior backup identified by --backup-stamp (preview by default)
  --backup-stamp <yyyyMMdd_HHmmss> Backup timestamp to restore with --restore
  -h, --help                       Show this help message
EOF
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

if [[ "$(uname -s)" != "Linux" ]]; then
    fail "MnemoSync-Linux.sh is for Linux only (detected $(uname -s))."
fi

NEW_PROJECT_PATH=""
OLD_FOLDER_NAME=""
APP_DATA_FOLDER_NAME="Antigravity IDE"
APPLY=0
VERIFY=0
CLEANUP=0
INCLUDE_BACKUPS=0
KEEP_BACKUP_DAYS=7
OVERWRITE_EXISTING_STATE=0
RENAME_ON_DISK=0
LIST_BACKUPS=0
RESTORE=0
BACKUP_STAMP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new-project-path)
            [[ $# -ge 2 ]] || fail "--new-project-path requires a value."
            NEW_PROJECT_PATH="$2"
            shift 2
            ;;
        --old-folder-name)
            [[ $# -ge 2 ]] || fail "--old-folder-name requires a value."
            OLD_FOLDER_NAME="$2"
            shift 2
            ;;
        --app-data-folder-name)
            [[ $# -ge 2 ]] || fail "--app-data-folder-name requires a value."
            APP_DATA_FOLDER_NAME="$2"
            shift 2
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        --verify)
            VERIFY=1
            shift
            ;;
        --cleanup)
            CLEANUP=1
            shift
            ;;
        --include-backups)
            INCLUDE_BACKUPS=1
            shift
            ;;
        --keep-backup-days)
            [[ $# -ge 2 ]] || fail "--keep-backup-days requires an integer value."
            KEEP_BACKUP_DAYS="$2"
            shift 2
            ;;
        --overwrite-existing-state)
            OVERWRITE_EXISTING_STATE=1
            shift
            ;;
        --rename-on-disk)
            RENAME_ON_DISK=1
            shift
            ;;
        --list-backups)
            LIST_BACKUPS=1
            shift
            ;;
        --restore)
            RESTORE=1
            shift
            ;;
        --backup-stamp)
            [[ $# -ge 2 ]] || fail "--backup-stamp requires a value."
            BACKUP_STAMP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

if ! [[ "$KEEP_BACKUP_DAYS" =~ ^[0-9]+$ ]] || (( KEEP_BACKUP_DAYS < 0 || KEEP_BACKUP_DAYS > 3650 )); then
    fail "--keep-backup-days must be an integer between 0 and 3650 (got '$KEEP_BACKUP_DAYS')."
fi

MODE_COUNT=$(( LIST_BACKUPS + RESTORE ))
if (( MODE_COUNT > 1 )); then
    fail "--list-backups and --restore cannot be combined."
fi
if (( (LIST_BACKUPS || RESTORE) && (VERIFY || CLEANUP || INCLUDE_BACKUPS || OVERWRITE_EXISTING_STATE || RENAME_ON_DISK) )); then
    fail "--list-backups / --restore cannot be combined with migration/verify/cleanup flags."
fi
if (( LIST_BACKUPS || RESTORE )) && [[ -n "$NEW_PROJECT_PATH" || -n "$OLD_FOLDER_NAME" ]]; then
    fail "--list-backups / --restore cannot be combined with --new-project-path or --old-folder-name."
fi
if (( APPLY && VERIFY )); then
    fail "--apply and --verify cannot be combined. --apply already runs the verification report when it finishes."
fi
if (( CLEANUP && VERIFY )); then
    fail "--cleanup already runs the verification report first; do not combine it with --verify."
fi
if (( INCLUDE_BACKUPS && ! CLEANUP )); then
    fail "--include-backups only applies together with --cleanup."
fi
if (( LIST_BACKUPS && APPLY )); then
    fail "--list-backups is read-only and cannot be combined with --apply."
fi
if (( RENAME_ON_DISK && (VERIFY || CLEANUP) )); then
    fail "--rename-on-disk cannot be combined with --verify or --cleanup."
fi
if (( OVERWRITE_EXISTING_STATE && (VERIFY || CLEANUP) )); then
    fail "--overwrite-existing-state cannot be combined with --verify or --cleanup."
fi
if (( RESTORE )) && [[ -z "$BACKUP_STAMP" ]]; then
    fail "--restore requires --backup-stamp <yyyyMMdd_HHmmss>."
fi
if (( RESTORE )) && ! [[ "$BACKUP_STAMP" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    fail "--backup-stamp must have format yyyyMMdd_HHmmss (got '$BACKUP_STAMP'). Run with --list-backups first."
fi
if (( ! LIST_BACKUPS && ! RESTORE )) && [[ -z "$NEW_PROJECT_PATH" || -z "$OLD_FOLDER_NAME" ]]; then
    fail "--new-project-path and --old-folder-name are required (use --help for usage)."
fi

check_path_syntax() {
    local val="$1"
    local name="$2"
    if [[ -z "${val//[[:space:]]/}" ]]; then
        fail "$name must not be empty."
    fi
    if [[ "$val" == *"<"* || "$val" == *">"* ]]; then
        fail "$name contains '<' or '>' ('$val'). It looks like you left a placeholder like <User> in the path. Replace it with a real path or use \$HOME."
    fi
    if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
        fail "$name contains control/newline characters."
    fi
}

PYTHON_EXE=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_EXE="python3"
elif command -v python >/dev/null 2>&1; then
    if python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON_EXE="python"
    fi
fi
if [[ -z "$PYTHON_EXE" ]]; then
    fail "Python 3 (python3) is required in PATH to perform transactional SQLite and Protobuf wire-level updates."
fi

resolve_realpath() {
    "$PYTHON_EXE" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

trim_trailing_slashes() {
    local p="$1"
    while [[ "$p" != "/" && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s\n' "$p"
}

READ_ONLY_RUN=0
if (( VERIFY || LIST_BACKUPS || (CLEANUP && ! APPLY) || (RESTORE && ! APPLY) )); then
    READ_ONLY_RUN=1
fi

RESOLVED_NEW_PATH=""
OLD_FULL_PATH=""

if (( ! LIST_BACKUPS && ! RESTORE )); then
    check_path_syntax "$NEW_PROJECT_PATH" "--new-project-path"
    check_path_syntax "$OLD_FOLDER_NAME" "--old-folder-name"

    TRIMMED_NEW="$(trim_trailing_slashes "$NEW_PROJECT_PATH")"
    TRIMMED_OLD="$(trim_trailing_slashes "$OLD_FOLDER_NAME")"
    OLD_LEAF="${TRIMMED_OLD##*/}"
    [[ -n "$OLD_LEAF" ]] || fail "--old-folder-name must not be empty."

    if (( RENAME_ON_DISK )); then
        NEW_LEAF="${TRIMMED_NEW##*/}"
        [[ -n "$NEW_LEAF" ]] || fail "--new-project-path must include a folder name: $NEW_PROJECT_PATH"
        if [[ "$TRIMMED_NEW" == */* ]]; then
            NEW_PARENT_RAW="${TRIMMED_NEW%/*}"
            [[ -n "$NEW_PARENT_RAW" ]] || NEW_PARENT_RAW="/"
        else
            NEW_PARENT_RAW="$PWD"
        fi
        [[ -d "$NEW_PARENT_RAW" ]] || fail "Parent directory for --new-project-path does not exist: $NEW_PARENT_RAW"
        RESOLVED_NEW_PARENT="$(trim_trailing_slashes "$(resolve_realpath "$NEW_PARENT_RAW")")"
        if [[ "$RESOLVED_NEW_PARENT" == "/" ]]; then
            RESOLVED_NEW_PATH="/$NEW_LEAF"
        else
            RESOLVED_NEW_PATH="$RESOLVED_NEW_PARENT/$NEW_LEAF"
        fi

        if [[ "$TRIMMED_OLD" == /* ]]; then
            OLD_FULL_PATH="$TRIMMED_OLD"
        elif [[ "$RESOLVED_NEW_PARENT" == "/" ]]; then
            OLD_FULL_PATH="/$OLD_LEAF"
        else
            OLD_FULL_PATH="$RESOLVED_NEW_PARENT/$OLD_LEAF"
        fi

        [[ "$OLD_FULL_PATH" != "$RESOLVED_NEW_PATH" ]] || fail "Old path ('$OLD_FULL_PATH') and target path are identical; nothing to rename."
        [[ -d "$OLD_FULL_PATH" ]] || fail "Source project directory to rename does not exist: $OLD_FULL_PATH"
        OLD_FULL_PATH="$(trim_trailing_slashes "$(resolve_realpath "$OLD_FULL_PATH")")"
        [[ ! -e "$RESOLVED_NEW_PATH" ]] || fail "Target project directory already exists: $RESOLVED_NEW_PATH. Remove --rename-on-disk if you already renamed it on disk."
    else
        [[ -d "$TRIMMED_NEW" ]] || fail "Target project directory does not exist: $NEW_PROJECT_PATH"
        RESOLVED_NEW_PATH="$(trim_trailing_slashes "$(resolve_realpath "$TRIMMED_NEW")")"
        NEW_PARENT="${RESOLVED_NEW_PATH%/*}"
        [[ -n "$NEW_PARENT" ]] || NEW_PARENT="/"

        if [[ "$TRIMMED_OLD" == /* ]]; then
            OLD_FULL_PATH="$TRIMMED_OLD"
        elif [[ "$NEW_PARENT" == "/" ]]; then
            OLD_FULL_PATH="/$OLD_LEAF"
        else
            OLD_FULL_PATH="$NEW_PARENT/$OLD_LEAF"
        fi

        [[ "$OLD_FULL_PATH" != "$RESOLVED_NEW_PATH" ]] || fail "Old path ('$OLD_FULL_PATH') and target path are identical; nothing to migrate."
        if [[ -e "$OLD_FULL_PATH" ]] && (( ! VERIFY && ! CLEANUP )); then
            fail "The old path still exists on disk: $OLD_FULL_PATH. Rename/move the folder first (or pass --rename-on-disk)."
        fi
    fi
fi

CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
APP_DATA_ROOT="${CONFIG_BASE%/}/$APP_DATA_FOLDER_NAME"
USER_DIR="$APP_DATA_ROOT/User"
GEMINI_ROOT="$HOME/.gemini"

[[ -d "$USER_DIR" ]] || fail "Antigravity User directory not found: $USER_DIR"

# Ensure Antigravity is closed and no SQLite locks exist for write operations
ANTIGRAVITY_RUNNING=0
if ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" -v parent="$PPID" '
    $1 == self || $1 == parent { next }
    tolower($0) ~ /mnemosync-linux|python[0-9.]*[[:space:]].*unittest/ { next }
    tolower($0) ~ /antigravity/ { found = 1 }
    END { exit(found ? 0 : 1) }
'; then
    ANTIGRAVITY_RUNNING=1
fi

if (( ANTIGRAVITY_RUNNING && READ_ONLY_RUN )); then
    printf 'NOTE: Antigravity is running. This run is read-only and checks what is on disk right now; close Antigravity first for the most reliable result.\n'
elif (( ANTIGRAVITY_RUNNING )); then
    fail "Antigravity is currently running. Close all windows (IDE and agent app) and terminate background processes first."
fi

if (( ! READ_ONLY_RUN )); then
    LOCK_HIT="$(find "$USER_DIR" \( -name '*.vscdb-wal' -o -name '*.vscdb-journal' \) 2>/dev/null | head -n 1 || true)"
    if [[ -n "$LOCK_HIT" ]]; then
        fail "Active SQLite lock files (.vscdb-wal / .vscdb-journal) found. Close Antigravity completely before running."
    fi
fi

RENAMED_ON_DISK=0
RENAME_DRYRUN=0
USER_BACKUP_PATH=""
FILE_BACKUP_DIR=""

cleanup_temp() {
    if [[ -n "${TEMP_PY:-}" && -f "$TEMP_PY" ]]; then
        rm -f "$TEMP_PY"
    fi
}
trap cleanup_temp EXIT

if (( RENAME_ON_DISK )); then
    if (( APPLY )); then
        printf '[Rename]    Renaming on disk: %s -> %s\n' "$OLD_FULL_PATH" "$RESOLVED_NEW_PATH"
        mv "$OLD_FULL_PATH" "$RESOLVED_NEW_PATH"
        RENAMED_ON_DISK=1
        RESOLVED_NEW_PATH="$(trim_trailing_slashes "$(resolve_realpath "$RESOLVED_NEW_PATH")")"
    else
        printf '[Rename]    Would rename on disk: %s -> %s\n' "$OLD_FULL_PATH" "$RESOLVED_NEW_PATH"
        RENAME_DRYRUN=1
    fi
fi

if (( APPLY && ! CLEANUP && ! LIST_BACKUPS && ! RESTORE )); then
    STAMP="$(date +%Y%m%d_%H%M%S)"
    USER_BACKUP_PATH="$APP_DATA_ROOT/User_AutoBackup_$STAMP"
    FILE_BACKUP_DIR="$APP_DATA_ROOT/Migration_FileBackup_$STAMP"
    printf '[Backup] Creating User directory backup: %s\n' "$USER_BACKUP_PATH"
    cp -a "$USER_DIR" "$USER_BACKUP_PATH"
    printf '[Backup] Per-file backups (incl. .gemini) will go to: %s\n' "$FILE_BACKUP_DIR"
fi

TEMP_PY="$(mktemp "${TMPDIR:-/tmp}/ag_migrate_XXXXXX.py")"
cat <<'__AG_MIGRATE_PY__' > "$TEMP_PY"
import base64
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import traceback
from pathlib import Path, PurePosixPath
from urllib.parse import quote, unquote, urlparse

if os.name != "posix":
    sys.exit("This script supports POSIX systems only.")

CASE_INSENSITIVE = False
APP_ROOT = Path(os.environ.get("AG_APP_ROOT") or Path(os.environ["AG_USER_DIR"]).parent)
USER_DIR = Path(os.environ["AG_USER_DIR"])
GEMINI_ROOT = Path(os.environ["AG_GEMINI_ROOT"])
APPLY = os.environ["AG_APPLY"] == "1"
VERIFY = os.environ.get("AG_VERIFY") == "1"
CLEANUP = os.environ.get("AG_CLEANUP") == "1"
INCLUDE_BACKUPS = os.environ.get("AG_INCLUDE_BACKUPS") == "1"
KEEP_DAYS = int(os.environ.get("AG_KEEP_DAYS", "7"))
OVERWRITE_STATE = os.environ.get("AG_OVERWRITE_STATE") == "1"
RENAME_DRYRUN = os.environ.get("AG_RENAME_DRYRUN") == "1"
LIST_BACKUPS = os.environ.get("AG_LIST_BACKUPS") == "1"
RESTORE_STAMP = os.environ.get("AG_RESTORE_STAMP", "").strip()
BACKUP_DIR = Path(os.environ["AG_BACKUP_DIR"]) if os.environ.get("AG_BACKUP_DIR") else None

NEW_PATH_RAW = os.environ.get("AG_NEW_PATH", "")
OLD_PATH_ARG = os.environ.get("AG_OLD_PATH", "")
NEW_PATH = Path(os.path.realpath(NEW_PATH_RAW)) if NEW_PATH_RAW else None
NEW_NAME = NEW_PATH.name if NEW_PATH else ""

MAX_DEPTH = 8
S = {"changed": 0}

# ---------------------------------------------------------------------------
# Path matching: full OLD POSIX path, raw / percent-encoded / double-encoded
# ---------------------------------------------------------------------------
SEP = r"(?:/+|%(?:25)?2F)"
SUFFIX = r"(?=\Z|[^\w.\-~%]|\.(?![\w\-])|%(?:25)?(?:2F|22|27|29|2C|3B|5D|7D))"
PREFIX_BOUND = r"(?:(?<=file://)|(?<=%2F%2F)|(?<=%2f%2f)|(?<=%252F%252F)|(?<=%252f%252f)|(?<![A-Za-z0-9._~/]))"


def norm_path(p) -> str:
    s = os.path.normpath(str(p))
    return s.lower() if CASE_INSENSITIVE else s


def norm_eq(a: str, b: str) -> bool:
    return a.lower() == b.lower() if CASE_INSENSITIVE else a == b


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
            if CASE_INSENSITIVE:
                parts.append("(?:%s|%s|%s)" % (re.escape(ch), enc, dbl))
            else:
                enc_lo = "".join("%%%02x" % b for b in bs)
                dbl_lo = "".join("%%25%02x" % b for b in bs)
                parts.append("(?:%s|%s|%s|%s|%s)" % (re.escape(ch), enc, enc_lo, dbl, dbl_lo))
    return "".join(parts)


def build_path_regex(pw: PurePosixPath, force_ci: bool = False):
    """Compiled regex matching a full POSIX path in any textual encoding (groups: parent, leaf)."""
    if not pw.is_absolute() or len(pw.parts) < 2:
        raise RuntimeError("Expected an absolute POSIX path: %s" % pw)
    segs = [x for x in pw.parts if x != "/"]
    leaf, parent = segs[-1], segs[:-1]
    parent_re = SEP + "".join(tolerant(x) + SEP for x in parent)
    flags = re.I if (CASE_INSENSITIVE or force_ci) else 0
    return re.compile(
        PREFIX_BOUND + r"(?P<parent>" + parent_re + r")(?P<leaf>" + tolerant(leaf) + r")" + SUFFIX,
        flags,
    )


def set_old_path(p) -> None:
    pw = PurePosixPath(str(p))
    segs = [x for x in pw.parts if x != "/"]
    leaf = segs[-1] if segs else ""
    S["pattern"] = build_path_regex(pw)
    S["pattern_ci"] = build_path_regex(pw, force_ci=True)
    S["hint"] = re.compile(tolerant(leaf), re.I if CASE_INSENSITIVE else 0)
    S["hint_ci"] = re.compile(tolerant(leaf), re.I)
    S["old_leaf"] = leaf
    S["old_path"] = pw
    S["same_parent"] = norm_path(pw.parent) == norm_path(PurePosixPath(str(NEW_PATH)).parent)


def render_parent(parent_text: str) -> str:
    """Render NEW parent directory in the same textual style as the matched OLD parent."""
    p = PurePosixPath(str(NEW_PATH.parent))
    msep = re.search(SEP, parent_text, re.I).group(0)
    segs = [x for x in p.parts if x != "/"]
    if "%" in parent_text:
        segs = [quote(x, safe="") for x in segs]
    return msep + "".join(x + msep for x in segs)


def _repl(m):
    parent, leaf = m.group("parent"), m.group("leaf")
    before = m.string[max(0, m.start() - 12):m.start()]
    encode = "%" in parent or "%" in leaf or re.search(r"file:/*$", before, re.I) is not None
    new_leaf = quote(NEW_NAME, safe="") if encode else NEW_NAME
    return (parent if S["same_parent"] else render_parent(parent)) + new_leaf


def apply_path_patterns(s: str) -> str:
    ci = bool(S.get("lower_keys"))
    hint = S["hint_ci"] if ci else S["hint"]
    pat = S["pattern_ci"] if ci else S["pattern"]
    if not hint.search(s):
        return s
    return pat.sub(_repl, s)


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
            if kc and isinstance(v, str) and (
                v.strip().lower() == S["old_leaf"].lower() if S.get("lower_keys") else norm_eq(v.strip(), S["old_leaf"])
            ):
                nv, vc = (NEW_NAME.lower() if S.get("lower_keys") else NEW_NAME), True
            new_dict[nk] = nv
            changed = changed or kc or vc
            if k == "projectResources" and (kc or vc):
                key_changed_values.append(True)
        # Antigravity project file: bare display name equal to the old folder name
        if key_changed_values and isinstance(new_dict.get("name"), str) \
                and norm_eq(new_dict["name"].strip(), S["old_leaf"]):
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
# VS Code workspace & history identity helpers (Linux: st_ino)
# ---------------------------------------------------------------------------
def get_linux_inode(target: Path) -> int:
    """Inode number, matching VS Code on Linux: fileStat.ino."""
    if RENAME_DRYRUN and not target.exists() and S.get("old_path") and Path(str(S["old_path"])).exists():
        target = Path(str(S["old_path"]))
    return os.stat(target).st_ino


def workspace_hash(target: Path, bt_source: Path = None) -> str:
    """Compute VS Code workspaceStorage hash on Linux (fsPath + inode)."""
    ino = get_linux_inode(bt_source or target)
    return hashlib.md5((str(target) + str(ino)).encode("utf-8")).hexdigest()


def vscode_string_hash(s: str) -> str:
    """Exact VS Code stringHash(s, 0) used for User/History folder names."""
    h = 149417  # numberHash(149417, 0)
    for ch in s:
        h = (((h << 5) - h) + ord(ch)) & 0xFFFFFFFF
    if h >= 0x80000000:
        h -= 0x100000000
    return f"-{-h:x}" if h < 0 else f"{h:x}"


def vscode_uri(p: Path) -> str:
    return "file://" + quote(str(p), safe="/")


def uri_to_path(uri: str):
    if not uri:
        return None
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    return unquote(parsed.path)


def newest(paths):
    def key(d):
        f = d / "state.vscdb"
        return (f if f.exists() else d).stat().st_mtime
    return max(paths, key=key)


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
# Backup listing and one-command restore (--list-backups / --restore)
# ---------------------------------------------------------------------------
STAMP_RE = re.compile(r"^\d{8}_\d{6}$")


def list_backups() -> int:
    specs = [
        (APP_ROOT, re.compile(r"^(User_AutoBackup)_(\d{8}_\d{6})$"), "User directory snapshot"),
        (APP_ROOT, re.compile(r"^(Migration_FileBackup)_(\d{8}_\d{6})$"), "Per-file backup + manifest"),
        (GEMINI_ROOT, re.compile(r"^(antigravity_AutoBackup)_(\d{8}_\d{6})$"), "Legacy .gemini snapshot"),
    ]
    by_stamp = {}
    for root, rx, _desc in specs:
        if not root.is_dir():
            continue
        for d in root.iterdir():
            if not d.is_dir():
                continue
            m = rx.match(d.name)
            if not m:
                continue
            kind, stamp = m.group(1), m.group(2)
            info = {"path": d, "size": dir_size(d)}
            if kind == "Migration_FileBackup":
                mf = d / "manifest.jsonl"
                if mf.is_file():
                    info["entries"] = sum(1 for ln in mf.read_text(encoding="utf-8").splitlines() if ln.strip())
            by_stamp.setdefault(stamp, {})[kind] = info

    print("\n===== Available migration backups =====")
    if not by_stamp:
        print("No backups found under %s or %s." % (APP_ROOT, GEMINI_ROOT))
        return 0
    for stamp in sorted(by_stamp.keys(), reverse=True):
        parts = []
        for kind in ("User_AutoBackup", "Migration_FileBackup", "antigravity_AutoBackup"):
            if kind in by_stamp[stamp]:
                item = by_stamp[stamp][kind]
                extra = ", %d manifest entries" % item["entries"] if "entries" in item else ""
                parts.append("%s (%s%s)" % (kind, human(item["size"]), extra))
        print("%s  |  %s" % (stamp, " ; ".join(parts)))
    newest_stamp = sorted(by_stamp.keys(), reverse=True)[0]
    print("\nPreview restore : --restore --backup-stamp %s" % newest_stamp)
    print("Apply restore   : --restore --backup-stamp %s --apply" % newest_stamp)
    return 0


def restore_backup(stamp: str, do_apply: bool) -> int:
    if not STAMP_RE.match(stamp):
        print("ERROR: Invalid backup stamp '%s'. Expected yyyyMMdd_HHmmss." % stamp)
        return 1
    user_bak = APP_ROOT / ("User_AutoBackup_" + stamp)
    file_bak = APP_ROOT / ("Migration_FileBackup_" + stamp)
    has_user = user_bak.is_dir()
    has_file = file_bak.is_dir()
    if not has_user and not has_file:
        print("ERROR: No backup found for stamp '%s' under %s." % (stamp, APP_ROOT))
        return 1

    manifest_entries = []
    manifest_file = file_bak / "manifest.jsonl"
    if manifest_file.is_file():
        for ln in manifest_file.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if ln:
                manifest_entries.append(json.loads(ln))
    elif has_file and not has_user:
        print("ERROR: Backup %s has no manifest.jsonl and no User_AutoBackup exists for this stamp." % file_bak)
        return 1

    user_norm = norm_path(USER_DIR)

    def inside_user(p: Path) -> bool:
        pn = norm_path(p)
        return pn == user_norm or pn.startswith(user_norm + os.sep)

    print("\n===== Restore from backup %s (%s) =====" % (stamp, "APPLYING" if do_apply else "preview - nothing modified"))
    if has_user:
        print("[RESTORE] User directory <- %s" % user_bak)

    file_actions = []
    for entry in reversed(manifest_entries):
        if "orig" in entry and "backup" in entry:
            orig = Path(entry["orig"])
            bak = Path(entry["backup"])
            if has_user and inside_user(orig):
                continue
            file_actions.append(("copy", orig, bak))
            print("[RESTORE] %s <- %s" % (orig, bak.name))
        elif "created" in entry:
            created = Path(entry["created"])
            if has_user and inside_user(created):
                continue
            if created.exists():
                file_actions.append(("delete", created, None))
                print("[REMOVE]  %s (created during migration)" % created)

    if not do_apply:
        print("\nStatus: RESTORE PREVIEW COMPLETE (re-run with --apply to restore)")
        return 0

    db_to_check = []
    if has_user:
        if USER_DIR.exists():
            shutil.rmtree(USER_DIR, onerror=_force_remove)
        shutil.copytree(user_bak, USER_DIR)
        for db in USER_DIR.rglob("*.vscdb"):
            if db.is_file():
                db_to_check.append(db)

    for action, target, src in file_actions:
        if action == "copy":
            if not src.is_file():
                print("ERROR: Missing backup file %s" % src)
                return 1
            for ext in ("-wal", "-shm", "-journal"):
                side = Path(str(target) + ext)
                if side.exists():
                    side.unlink()
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
            if target.suffix.lower() in (".db", ".vscdb"):
                db_to_check.append(target)
        elif action == "delete" and target.exists():
            if target.is_dir():
                shutil.rmtree(target, onerror=_force_remove)
            else:
                target.unlink()

    seen_db = set()
    for db in db_to_check:
        norm = norm_path(db)
        if norm in seen_db or not db.is_file():
            continue
        seen_db.add(norm)
        ok, _ = db_health(db, check_item_table=False)
        if ok != "ok":
            print("ERROR: Integrity check failed on restored database %s: %s" % (db, ok))
            return 1

    print("\nStatus: RESTORE COMPLETED SUCCESSFULLY (verified %d database(s))" % len(seen_db))
    return 0


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
    is_proj_map = path.name.lower() == "projects.json" and path.parent == GEMINI_ROOT
    hint = S["hint_ci"] if is_proj_map else S["hint"]
    if not hint.search(text) and kind != "json":
        return False
    out = None
    if kind == "json":
        try:
            parsed = json.loads(text)
        except ValueError:
            kind = "text"
        else:
            S["lower_keys"] = is_proj_map
            try:
                new_parsed, changed = transform_json_node(parsed)
            finally:
                S["lower_keys"] = False
            if not changed:
                return False
            S["lower_keys"] = is_proj_map
            try:
                candidate = apply_path_patterns(text)
            finally:
                S["lower_keys"] = False
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


def collect_fts_changes(conn, shown: str):
    """Collect workspace/project column updates in conversations_fts for migrated conversations."""
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    if "conversation_summaries" not in tables or "conversations_fts" not in tables:
        return []
    new_pat = build_path_regex(PurePosixPath(str(NEW_PATH)))
    old_pat = S["pattern"]
    old_leaf = S["old_leaf"]
    old_enc = quote(old_leaf, safe="")
    new_enc = quote(NEW_NAME, safe="")

    cids = set()
    for cid, w_uris in conn.execute("SELECT conversation_id, workspace_uris FROM conversation_summaries"):
        if isinstance(w_uris, str) and (old_pat.search(w_uris) or new_pat.search(w_uris)):
            cids.add(cid)
    if not cids:
        return []

    fts_changes = []
    cid_list = list(cids)
    for i in range(0, len(cid_list), 200):
        chunk = cid_list[i:i + 200]
        ph = ",".join("?" for _ in chunk)
        rows = conn.execute(
            "SELECT rowid, conversation_id, workspace, project FROM conversations_fts "
            "WHERE conversation_id IN (%s)" % ph,
            chunk,
        ).fetchall()
        for rowid, cid, ws, proj in rows:
            new_ws = ws
            new_proj = proj
            if isinstance(ws, str):
                if norm_eq(ws, old_enc):
                    new_ws = new_enc
                elif norm_eq(ws, old_leaf):
                    new_ws = NEW_NAME
            if isinstance(proj, str) and norm_eq(proj, old_leaf):
                new_proj = NEW_NAME
            if new_ws != ws or new_proj != proj:
                fts_changes.append((rowid, cid, new_ws, new_proj))
                log("SQLite", "%s -> conversations_fts [conversation_id=%s]" % (shown, cid))
    return fts_changes


def process_sqlite(db_path: Path, tx: Tx, shown: str):
    if not db_path.is_file():
        return
    changes = []
    fts_changes = []
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
        if db_path.name.lower() == "conversation_summaries.db":
            try:
                fts_changes = collect_fts_changes(conn, shown)
            except sqlite3.Error as exc:
                print("[SQLite]    skipped FTS5 in %s (%s)" % (shown, exc))
        if not (APPLY and (changes or fts_changes)):
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
        for rowid, _cid, new_ws, new_proj in fts_changes:
            rw.execute(
                "UPDATE conversations_fts SET workspace = ?, project = ? WHERE rowid = ?",
                (new_ws, new_proj, rowid),
            )
        rw.commit()
        if fts_changes:
            rw.execute("INSERT INTO conversations_fts(conversations_fts) VALUES('integrity-check');")
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


def copy_workspace_state_if_safe(old_ws_dir: Path, new_ws_dir: Path, tx: Tx) -> bool:
    """Copy workspaceStorage state unless the target DB is already newer and populated."""
    if old_ws_dir == new_ws_dir:
        return True
    new_db = new_ws_dir / "state.vscdb"
    old_db = old_ws_dir / "state.vscdb"
    if new_db.is_file() and old_db.is_file() and not OVERWRITE_STATE:
        ok_n, new_cnt = db_health(new_db)
        ok_o, old_cnt = db_health(old_db)
        if ok_n == "ok" and ok_o == "ok" and new_db.stat().st_mtime > old_db.stat().st_mtime and new_cnt >= old_cnt:
            print(
                "[Workspace] Target state.vscdb is newer and already populated (%d vs %d entries); "
                "skipping state copy to protect newer UI state. Pass --overwrite-existing-state to force."
                % (new_cnt, old_cnt)
            )
            return False
    print("[Workspace] Copy state & extensions: %s -> %s (preserving workspace.json)"
          % (old_ws_dir.name, new_ws_dir.name))
    if APPLY:
        copy_tree_tracked(old_ws_dir, new_ws_dir, tx)
    return True


def migrate_local_history(tx: Tx):
    """Migrate VS Code Local History (User/History/<stringHash>/entries.json)."""
    hist_root = USER_DIR / "History"
    if not hist_root.is_dir():
        return
    for d in sorted(hist_root.iterdir()):
        ej = d / "entries.json"
        if not (d.is_dir() and ej.is_file()):
            continue
        try:
            data = json.loads(ej.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        resource = data.get("resource")
        if not isinstance(resource, str):
            continue
        new_res, ch = transform_string(resource)
        if not ch:
            continue
        target_name = vscode_string_hash(new_res)
        target_dir = hist_root / target_name
        log("History", "User/History/%s -> %s" % (d.name, target_name))
        if not APPLY:
            continue

        if d != target_dir:
            if not target_dir.exists():
                tx.track_created(target_dir)
                target_dir.mkdir(parents=True)
            for item in d.iterdir():
                if item.name == "entries.json" or not item.is_file():
                    continue
                dest = target_dir / item.name
                if not dest.exists():
                    tx.track_created(dest)
                    shutil.copy2(item, dest)

        target_ej = target_dir / "entries.json"
        data["resource"] = new_res
        if target_ej.is_file():
            tx.backup_file(target_ej)
            if d != target_dir:
                try:
                    existing = json.loads(target_ej.read_text(encoding="utf-8-sig"))
                    merged = {}
                    for e in data.get("entries", []):
                        if isinstance(e, dict) and "id" in e:
                            merged[e["id"]] = e
                    for e in existing.get("entries", []):
                        if isinstance(e, dict) and "id" in e:
                            merged[e["id"]] = e
                    data["entries"] = sorted(merged.values(), key=lambda x: x.get("timestamp", 0))
                except Exception:
                    pass
        else:
            tx.track_created(target_ej)
        target_ej.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def migrate_multiroot_workspaces(tx: Tx):
    """Migrate multi-root .code-workspace storage entries and rewrite paths inside .code-workspace files."""
    ws_root = USER_DIR / "workspaceStorage"
    if not ws_root.is_dir():
        return
    backups_root = USER_DIR.parent / "Backups"
    old_pat = S["pattern"]
    seen_files = set()
    ws_files_to_update = []

    for d in sorted(ws_root.iterdir()):
        wj = d / "workspace.json"
        if not (d.is_dir() and wj.is_file()):
            continue
        try:
            data = json.loads(wj.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        ws_uri = data.get("workspace")
        if not isinstance(ws_uri, str):
            continue
        ws_raw = uri_to_path(ws_uri)
        if not ws_raw:
            continue

        if old_pat.search(ws_uri) or old_pat.search(ws_raw):
            new_uri_str, _ = transform_string(ws_uri)
            new_raw = uri_to_path(new_uri_str)
            if not new_raw:
                continue
            new_ws_file = Path(new_raw)
            old_ws_file = Path(ws_raw)
            if new_ws_file.is_file():
                target_hash = workspace_hash(new_ws_file)
            elif RENAME_DRYRUN and old_ws_file.is_file():
                target_hash = workspace_hash(new_ws_file, bt_source=old_ws_file)
            else:
                target_hash = None

            if target_hash:
                target_dir = ws_root / target_hash
                print("[Workspace] Multi-root storage: %s -> %s" % (d.name, target_hash))
                if APPLY:
                    if not target_dir.exists():
                        tx.track_created(target_dir)
                        target_dir.mkdir(parents=True)
                    twj = target_dir / "workspace.json"
                    if not twj.exists():
                        tx.track_created(twj)
                        with open(twj, "w", encoding="utf-8", newline="\n") as fh:
                            fh.write(json.dumps({"workspace": vscode_uri(new_ws_file)}, indent=2))
                copied = copy_workspace_state_if_safe(d, target_dir, tx)
                old_bak, new_bak = backups_root / d.name, backups_root / target_dir.name
                if old_bak.exists() and not new_bak.exists() and d != target_dir:
                    print("[Backups]   Migrate hot-exit folder: %s -> %s" % (old_bak.name, new_bak.name))
                    if APPLY:
                        tx.track_created(new_bak)
                        shutil.copytree(old_bak, new_bak)
                        for meta in new_bak.rglob("meta.json"):
                            process_text_file(
                                meta, "json", tx, "Backups",
                                "Backups/%s" % meta.relative_to(backups_root).as_posix(), backup=False,
                            )
                db_dir = target_dir if (APPLY or not copied) else d
                process_sqlite(db_dir / "state.vscdb", tx, "workspaceStorage/%s/state.vscdb" % db_dir.name)

            cand_file = old_ws_file if (RENAME_DRYRUN and old_ws_file.is_file()) else new_ws_file
            if cand_file.is_file():
                ws_files_to_update.append(cand_file)
        else:
            ws_file = Path(ws_raw)
            if ws_file.is_file():
                ws_files_to_update.append(ws_file)

    for ws_file in ws_files_to_update:
        norm = norm_path(ws_file)
        if norm in seen_files:
            continue
        seen_files.add(norm)
        process_text_file(ws_file, "json", tx, "WorkspaceFile", str(ws_file))


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


def db_health(db_path: Path, check_item_table: bool = True):
    try:
        conn = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True)
        try:
            ok = conn.execute("PRAGMA integrity_check;").fetchone()[0]
            n = conn.execute("SELECT COUNT(*) FROM ItemTable").fetchone()[0] if check_item_table else 0
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
    expected_new = norm_path(NEW_PATH)
    expected_old = norm_path(S["old_path"])
    new_pat = build_path_regex(PurePosixPath(str(NEW_PATH)))
    old_pat = S["pattern"]
    ws_root = USER_DIR / "workspaceStorage"
    expected_hash = workspace_hash(NEW_PATH)
    new_dirs, old_dirs = [], []
    multi_old_dirs, multi_live_dirs, multi_stale_dirs = [], [], []
    ws_files_to_check = []
    if ws_root.is_dir():
        for d in ws_root.iterdir():
            try:
                wdata = json.loads((d / "workspace.json").read_text(encoding="utf-8-sig"))
            except Exception:
                continue
            raw = uri_to_path(wdata.get("folder", ""))
            if raw is not None:
                norm = norm_path(raw)
                if norm == expected_new:
                    new_dirs.append(d)
                elif norm == expected_old:
                    old_dirs.append(d)
                continue
            ws_uri = wdata.get("workspace", "")
            ws_raw = uri_to_path(ws_uri) if isinstance(ws_uri, str) else None
            if ws_raw:
                ws_file = Path(ws_raw)
                if ws_file.is_file():
                    ws_files_to_check.append(ws_file)
                if old_pat.search(ws_uri) or old_pat.search(ws_raw):
                    multi_old_dirs.append(d)
                elif new_pat.search(ws_uri) or new_pat.search(ws_raw):
                    if ws_file.is_file() and d.name == workspace_hash(ws_file):
                        multi_live_dirs.append(d)
                    else:
                        multi_stale_dirs.append(d)

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
        elif folder and norm_path(uri_to_path(folder) or "") == expected_new:
            add("WARN", "workspace.json points to the new folder but in a non-canonical form", folder)
        else:
            add("FAIL", "workspace.json does not point to the new folder", str(folder))
    elif new_dirs:
        add("FAIL", "Workspace is registered under a hash the IDE will NOT use for this folder",
            "found: %s | expected: %s" % (", ".join(d.name for d in new_dirs), expected_hash))
    elif multi_live_dirs:
        add("PASS", "Multi-root .code-workspace storage exists under the IDE hash",
            ", ".join(d.name for d in multi_live_dirs))
    elif multi_stale_dirs:
        add("FAIL", "Multi-root workspace is registered under a hash the IDE will NOT use",
            ", ".join(d.name for d in multi_stale_dirs))
    else:
        add("FAIL", "No workspaceStorage entry for the new folder",
            "expected %s - run the migration (or open the folder once, then migrate)" % expected_hash)
    stale = [d.name for d in new_dirs if d.name != expected_hash] + [d.name for d in multi_stale_dirs]
    if stale and (exp_dir.is_dir() or multi_live_dirs):
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

    if ws_files_to_check:
        ws_file_refs = []
        seen_wsf = set()
        for wsf in ws_files_to_check:
            norm = norm_path(wsf)
            if norm in seen_wsf:
                continue
            seen_wsf.add(norm)
            ws_file_refs += capture(process_text_file, wsf, "json", tx, "WorkspaceFile", str(wsf))
        if ws_file_refs:
            add("FAIL", "Multi-root .code-workspace file(s) still reference the OLD path",
                "; ".join(l.split("]", 1)[1].strip() for l in ws_file_refs[:5]))
        else:
            add("PASS", "Multi-root .code-workspace file(s) contain no references to the old path")

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

    # 3b. Local History (User/History) -------------------------------------
    hist_root = USER_DIR / "History"
    unmigrated_hist, old_hist_dirs = [], []
    if hist_root.is_dir():
        for d in sorted(hist_root.iterdir()):
            ej = d / "entries.json"
            if not (d.is_dir() and ej.is_file()):
                continue
            try:
                res_uri = json.loads(ej.read_text(encoding="utf-8-sig")).get("resource")
            except Exception:
                continue
            if not isinstance(res_uri, str):
                continue
            new_res, ch = transform_string(res_uri)
            if not ch:
                continue
            target_dir = hist_root / vscode_string_hash(new_res)
            if (target_dir / "entries.json").is_file():
                if d != target_dir:
                    old_hist_dirs.append((d, target_dir))
            else:
                unmigrated_hist.append(d.name)
    if unmigrated_hist:
        add("FAIL", "%d Local History folder(s) were not migrated to the new path" % len(unmigrated_hist),
            ", ".join(unmigrated_hist[:5]))
    else:
        add("PASS", "Local History (User/History) has no unmigrated entries for the old path")

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
    link = [l for l in lines if l not in proj and (".pb" in l or "agyhub" in l or "antigravity_state" in l or "conversations_fts" in l)]
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
    all_old_dirs = old_dirs + multi_old_dirs
    stale_dirs = [d for d in new_dirs if d.name != expected_hash] + multi_stale_dirs
    S["verify_info"] = {
        "exp_dir": exp_dir,
        "live_multi_dirs": set(multi_live_dirs),
        "old_dirs": all_old_dirs,
        "stale": stale_dirs,
        "old_history": old_hist_dirs,
    }
    if all_old_dirs:
        add("INFO", "Old workspace entry still on disk (kept as a safety copy)",
            ", ".join(d.name for d in all_old_dirs) + " - safe to delete once you are satisfied")
    if old_hist_dirs:
        add("INFO", "%d migrated Local History safety copy folder(s) on disk" % len(old_hist_dirs),
            ", ".join(o.name for o, _ in old_hist_dirs[:5]))
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
        verdict = "NOT VERIFIED - %d check(s) failed. Re-run with --apply (Antigravity closed), then --verify again." % fails
    elif warns:
        verdict = "VERIFIED with %d warning(s) - the workspace link is intact; warnings are informational." % warns
    else:
        verdict = "VERIFIED - all checks passed."
    print("\nVerdict: " + verdict)
    if not fails and not CLEANUP and (all_old_dirs or stale_dirs or old_hist_dirs):
        print("Tip: leftovers can be removed with --cleanup (preview) / --cleanup --apply (delete).")
    return 2 if fails else 0


# ---------------------------------------------------------------------------
# Leftover cleanup (only after a clean verification)
# ---------------------------------------------------------------------------
HASH_RE = re.compile(r"^[0-9a-f]{32}$")
HIST_HASH_RE = re.compile(r"^-?[0-9a-f]{1,8}$")


def cleanup(do_delete: bool) -> int:
    from datetime import datetime, timedelta
    info = S["verify_info"]
    exp_dir = info["exp_dir"]
    protected_ws = {exp_dir} | set(info.get("live_multi_dirs", ()))
    ws_root = USER_DIR / "workspaceStorage"
    hist_root = USER_DIR / "History"
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
            if any((backups_root / p.name).is_dir() for p in protected_ws if p.is_dir()) or (backups_root / exp_dir.name).is_dir():
                items.append((b, "hot-exit backup of the removed workspace entry (migrated copy exists)", backups_root, HASH_RE))
            else:
                skipped.append("Backups/%s kept: it holds unsaved-file backups that were not migrated" % d.name)

    for old_h, new_h in info.get("old_history", []):
        if (new_h / "entries.json").is_file() and old_h != new_h:
            items.append((old_h, "migrated Local History folder (copy exists at %s)" % new_h.name, hist_root, HIST_HASH_RE))

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
        same_parent = norm_path(path.parent) == norm_path(parent)
        if not (same_parent and rx.match(path.name) and path not in protected_ws and path.is_dir() and not path.is_symlink()):
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
        print("\nWould free %s. Re-run with --cleanup --apply (Antigravity closed) to delete." % human(total))
    return 1 if failed else 0


# ===== MAIN =====
def run(tx: Tx):
    expected_old = norm_path(S["old_path"])
    expected_new = norm_path(NEW_PATH)
    ws_root = USER_DIR / "workspaceStorage"

    # Step 1: locate old / new workspaceStorage hash folders
    exact_old, new_cands, loose = [], [], []
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
            norm = norm_path(raw)
            if norm == expected_old:
                exact_old.append(d)
            if norm == expected_new and expected_new != expected_old:
                new_cands.append(d)
            elif norm not in (expected_old, expected_new) \
                    and norm_eq(Path(raw).name, S["old_leaf"]) and not os.path.exists(raw):
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
                           "as --old-folder-name." % (S["old_leaf"], ", ".join(d.name for d, _ in loose)))

    expected_hash = workspace_hash(NEW_PATH)
    new_ws_dir = None
    if (ws_root / expected_hash).is_dir():
        new_ws_dir = ws_root / expected_hash
    others = [d.name for d in new_cands if d.name != expected_hash]
    if others:
        print("[Workspace] Ignoring entries for the new folder under unused hashes: %s" % ", ".join(others))

    ws_copied = True
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
        ws_copied = copy_workspace_state_if_safe(old_ws_dir, new_ws_dir, tx)

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

    # Step 2: SQLite state (global + migrated workspace + multi-root .code-workspace)
    process_sqlite(USER_DIR / "globalStorage" / "state.vscdb", tx, "globalStorage/state.vscdb")
    candidates = [new_ws_dir, old_ws_dir] if (APPLY or not ws_copied) else [old_ws_dir, new_ws_dir]
    ws_db_dir = next((c for c in candidates if c), None)
    if ws_db_dir:
        process_sqlite(ws_db_dir / "state.vscdb", tx, "workspaceStorage/%s/state.vscdb" % ws_db_dir.name)
    migrate_multiroot_workspaces(tx)

    # Step 3: JSON state & Local History (User/History)
    process_text_file(USER_DIR / "globalStorage" / "storage.json", "json", tx, "JSON", "globalStorage/storage.json")
    process_text_file(USER_DIR.parent / "Backups" / "workspaces.json", "json", tx, "JSON", "Backups/workspaces.json")
    migrate_local_history(tx)

    # Step 4: .gemini (agent app + IDE + 2.0 projects + FTS5)
    scan_gemini(tx)

    print("\nItems %s: %d" % ("updated" if APPLY else "to update", S["changed"]))
    print("Status:", "APPLIED SUCCESSFULLY" if APPLY else "DRY RUN COMPLETE (re-run with --apply to commit changes)")


def main():
    global APPLY
    if LIST_BACKUPS:
        sys.exit(list_backups())
    if RESTORE_STAMP:
        do_restore = APPLY
        APPLY = False
        sys.exit(restore_backup(RESTORE_STAMP, do_restore))

    _old = PurePosixPath(OLD_PATH_ARG)
    set_old_path(PurePosixPath(os.path.realpath(str(_old.parent))) / _old.name)
    if CLEANUP:
        do_delete = APPLY
        APPLY = False
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
            APPLY = False
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
__AG_MIGRATE_PY__

export AG_NEW_PATH="$RESOLVED_NEW_PATH"
export AG_OLD_PATH="$OLD_FULL_PATH"
export AG_APP_ROOT="$APP_DATA_ROOT"
export AG_USER_DIR="$USER_DIR"
export AG_GEMINI_ROOT="$GEMINI_ROOT"
export AG_APPLY="$APPLY"
export AG_BACKUP_DIR="$FILE_BACKUP_DIR"
export AG_VERIFY="$VERIFY"
export AG_CLEANUP="$CLEANUP"
export AG_INCLUDE_BACKUPS="$INCLUDE_BACKUPS"
export AG_KEEP_DAYS="$KEEP_BACKUP_DAYS"
export AG_OVERWRITE_STATE="$OVERWRITE_EXISTING_STATE"
export AG_RENAME_DRYRUN="$RENAME_DRYRUN"
export AG_LIST_BACKUPS="$LIST_BACKUPS"
export AG_RESTORE_STAMP="$BACKUP_STAMP"
export PYTHONIOENCODING="utf-8"

set +e
"$PYTHON_EXE" "$TEMP_PY"
PY_EXIT=$?
set -e

if (( PY_EXIT == 2 )); then
    exit 2
fi
if (( PY_EXIT != 0 )); then
    printf 'WARNING: Migration encountered an error (exit code %d).\n' "$PY_EXIT" >&2
    if (( RENAMED_ON_DISK )) && [[ -d "$RESOLVED_NEW_PATH" ]]; then
        if mv "$RESOLVED_NEW_PATH" "$OLD_FULL_PATH"; then
            printf '[Rollback] Renamed project directory back to: %s\n' "$OLD_FULL_PATH"
        else
            printf 'WARNING: Could not rename project directory back to %s.\n' "$OLD_FULL_PATH" >&2
        fi
    fi
    if (( APPLY && ! CLEANUP && ! RESTORE )); then
        printf 'WARNING: The engine restores every file it modified. Safety copies: %s and %s\n' "$USER_BACKUP_PATH" "$FILE_BACKUP_DIR" >&2
    fi
    exit 1
fi
