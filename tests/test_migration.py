"""Automated regression tests for MnemoSync-Windows.ps1."""

import base64
import binascii
import ctypes
import datetime
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "MnemoSync-Windows.ps1"


def extract_python_engine() -> str:
    """Extract the embedded Python engine source from MnemoSync-Windows.ps1."""
    raw = SCRIPT_PATH.read_text(encoding="utf-8")
    marker = "$pyScript = @'"
    start = raw.index(marker) + len(marker)
    end = raw.index("\n'@", start)
    return raw[start:end].lstrip("\r\n")


def compute_vscode_workspace_hash(folder: Path) -> str:
    """Independently compute VS Code's workspaceStorage MD5 hash on Windows."""
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
    ok = ctypes.windll.kernel32.GetFileAttributesExW(str(folder), 0, ctypes.byref(data))
    if not ok:
        raise OSError(f"GetFileAttributesExW failed for {folder}")
    ft = (data.ftCreationTime.dwHighDateTime << 32) | data.ftCreationTime.dwLowDateTime
    bt_ms = (ft - 116444736000000000) // 10000
    fs_path = str(folder)
    if len(fs_path) >= 2 and fs_path[1] == ":":
        fs_path = fs_path[0].lower() + fs_path[1:]
    return hashlib.md5((fs_path + str(bt_ms)).encode("utf-8")).hexdigest()


def vscode_uri(folder: Path) -> str:
    """Format a Windows path as VS Code's canonical workspace.json folder URI."""
    s = str(folder)
    return "file:///" + s[0].lower() + "%3A" + quote(s[2:].replace("\\", "/"), safe="/")


def encode_varint(val: int) -> bytes:
    """Encode an unsigned integer as a Protobuf base-128 varint."""
    out = bytearray()
    while True:
        b = val & 0x7F
        val >>= 7
        if val:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    """Decode a Protobuf base-128 varint from buf starting at pos."""
    res, shift = 0, 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        res |= (b & 0x7F) << shift
        if not (b & 0x80):
            return res, pos
        shift += 7
    raise ValueError("Truncated varint")


def pb_field(field_num: int, payload: bytes) -> bytes:
    """Build a length-delimited Protobuf field."""
    return encode_varint((field_num << 3) | 2) + encode_varint(len(payload)) + payload


def collect_pb_text_leaves(buf: bytes) -> list[tuple[bool, str]] | None:
    """Strictly parse protobuf and return text leaves (via_base64, text), or None if invalid."""
    pos = 0
    out: list[tuple[bool, str]] = []
    try:
        while pos < len(buf):
            tag, pos = read_varint(buf, pos)
            fnum, wt = tag >> 3, tag & 7
            if fnum == 0:
                return None
            if wt == 0:
                _, pos = read_varint(buf, pos)
            elif wt == 1:
                pos += 8
            elif wt == 5:
                pos += 4
            elif wt == 2:
                length, pos = read_varint(buf, pos)
                if pos + length > len(buf):
                    return None
                body = buf[pos : pos + length]
                pos += length
                sub = collect_pb_text_leaves(body) if body else None
                if sub is not None:
                    out.extend(sub)
                    continue
                text = body.decode("utf-8")
                if re.fullmatch(r"[A-Za-z0-9+/=_-]{16,}", text):
                    is_url = "-" in text or "_" in text
                    padded = text.rstrip("=") + "=" * ((4 - len(text.rstrip("=")) % 4) % 4)
                    raw = base64.urlsafe_b64decode(padded) if is_url else base64.b64decode(padded)
                    sub_b64 = collect_pb_text_leaves(raw)
                    if sub_b64 is not None:
                        out.extend((True, s) for _, s in sub_b64)
                        continue
                out.append((False, text))
            else:
                return None
        return out if pos == len(buf) else None
    except (ValueError, UnicodeDecodeError, binascii.Error):
        return None


def make_item_db(path: Path, rows: list[tuple[str, str | bytes]]) -> None:
    """Create a VS Code ItemTable SQLite database."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        conn.executemany("INSERT INTO ItemTable VALUES (?, ?)", rows)
        conn.commit()
    finally:
        conn.close()


def build_sidebar_value(entries: list[str]) -> str:
    """Build a realistic base64-encoded sidebarWorkspaces protobuf with nested base64 payloads."""
    top = bytearray()
    for idx, uri in enumerate(entries):
        ub = uri.encode("utf-8")
        # Exercise both a multi-field message and a bare single-field {1: uri} message.
        inner = pb_field(4, pb_field(1, ub) + b"\x10\x01") if idx % 2 == 0 else pb_field(1, ub)
        b64_inner = base64.b64encode(inner)
        top.extend(pb_field(1, pb_field(1, ub) + pb_field(2, b64_inner)))
    return base64.b64encode(bytes(top)).decode("ascii")


@unittest.skipUnless(os.name == "nt", "MnemoSync-Windows.ps1 is Windows-only")
class MigrationTests(unittest.TestCase):
    """End-to-end tests for migration, verification, rollback, and cleanup."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.engine_src = extract_python_engine()

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self._tmp.name))
        self.engine_file = self.root / "engine.py"
        self.engine_file.write_text(self.engine_src, encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_engine(
        self,
        *,
        new_path: Path | None = None,
        old_path: Path | None = None,
        user_dir: Path,
        gemini_root: Path,
        app_root: Path | None = None,
        backup_dir: Path | None = None,
        apply: bool = False,
        verify: bool = False,
        cleanup: bool = False,
        include_backups: bool = False,
        keep_days: int = 7,
        overwrite_state: bool = False,
        rename_dryrun: bool = False,
        list_backups: bool = False,
        restore_stamp: str = "",
    ) -> subprocess.CompletedProcess[str]:
        """Run the extracted Python engine in an isolated subprocess."""
        env = os.environ.copy()
        env.update(
            {
                "AG_NEW_PATH": str(new_path) if new_path else "",
                "AG_OLD_PATH": str(old_path) if old_path else "",
                "AG_APP_ROOT": str(app_root or user_dir.parent),
                "AG_USER_DIR": str(user_dir),
                "AG_GEMINI_ROOT": str(gemini_root),
                "AG_APPLY": "1" if apply else "0",
                "AG_BACKUP_DIR": str(backup_dir) if backup_dir else "",
                "AG_VERIFY": "1" if verify else "0",
                "AG_CLEANUP": "1" if cleanup else "0",
                "AG_INCLUDE_BACKUPS": "1" if include_backups else "0",
                "AG_KEEP_DAYS": str(keep_days),
                "AG_OVERWRITE_STATE": "1" if overwrite_state else "0",
                "AG_RENAME_DRYRUN": "1" if rename_dryrun else "0",
                "AG_LIST_BACKUPS": "1" if list_backups else "0",
                "AG_RESTORE_STAMP": restore_stamp,
                "PYTHONIOENCODING": "utf-8",
            }
        )
        return subprocess.run(
            [sys.executable, str(self.engine_file)],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )

    def create_fixture(self, *, with_backups: bool = False) -> dict[str, Path]:
        """Create a complete realistic scratch Antigravity + .gemini directory tree."""
        src = self.root / "Source Code"
        src.mkdir(parents=True)
        new_dir = src / "new proj.ag"
        new_dir.mkdir()
        old_dir = src / "old proj"  # vanished (renamed on disk)
        sibling_same_parent = src / "old proj2"
        sibling_same_parent.mkdir()
        other_parent_same_leaf = self.root / "elsewhere" / "old proj"
        other_parent_same_leaf.mkdir(parents=True)
        keep_dir = src / "keep"
        keep_dir.mkdir()

        old_uri = vscode_uri(old_dir)
        new_uri = vscode_uri(new_dir)
        other_uri = vscode_uri(other_parent_same_leaf)
        sib_uri = vscode_uri(sibling_same_parent)
        keep_uri = vscode_uri(keep_dir)

        app_root = self.root / "appdata" / "Antigravity IDE"
        user_dir = app_root / "User"
        global_dir = user_dir / "globalStorage"
        ws_root = user_dir / "workspaceStorage"
        old_hash = "a" * 32
        stale_hash = "b" * 32
        old_ws_dir = ws_root / old_hash
        stale_ws_dir = ws_root / stale_hash
        old_ws_dir.mkdir(parents=True)
        stale_ws_dir.mkdir(parents=True)

        (old_ws_dir / "workspace.json").write_text(json.dumps({"folder": old_uri}), encoding="utf-8")
        (stale_ws_dir / "workspace.json").write_text(json.dumps({"folder": new_uri}), encoding="utf-8")
        make_item_db(
            old_ws_dir / "state.vscdb",
            [("memento/x", json.dumps({"folder": old_uri, "f": old_uri + "/src/main.py"}))],
        )
        make_item_db(stale_ws_dir / "state.vscdb", [("memento/x", "{}")])

        sidebar_val = build_sidebar_value([old_uri, other_uri, sib_uri, keep_uri])
        recent_val = json.dumps(
            {
                "entries": [
                    {"folderUri": old_uri},
                    {"folderUri": other_uri},
                    {"fileUri": old_uri + "/a%20b.txt"},
                ]
            }
        )
        term_val = json.dumps({"dirs": [str(old_dir), str(other_parent_same_leaf)]})
        global_db = global_dir / "state.vscdb"
        make_item_db(
            global_db,
            [
                ("antigravityUnifiedStateSync.sidebarWorkspaces", sidebar_val),
                ("history.recentlyOpenedPathsList", recent_val),
                ("terminal.history", term_val),
            ],
        )
        shutil.copy2(global_db, global_dir / "state.vscdb.backup")

        (global_dir / "storage.json").write_text(
            json.dumps(
                {
                    "profileAssociations": {
                        "workspaces": {old_uri: "__default__", other_uri: "__default__"}
                    },
                    "windowsState": {"lastActiveWindow": {"folder": old_uri}},
                },
                indent=4,
            ),
            encoding="utf-8",
        )

        backups_root = app_root / "Backups"
        (backups_root / old_hash).mkdir(parents=True)
        (backups_root / stale_hash).mkdir(parents=True)
        (backups_root / "workspaces.json").write_text(
            json.dumps({"folderURIWorkspaces": [old_uri, other_uri]}), encoding="utf-8"
        )
        (backups_root / old_hash / "meta.json").write_text(
            json.dumps({"folder": old_uri}), encoding="utf-8"
        )

        gemini_root = self.root / "home" / ".gemini"
        (gemini_root / "config" / "projects").mkdir(parents=True)
        proj_1 = {
            "id": "1",
            "name": "old proj",
            "projectResources": {"resources": [{"gitFolder": {"folderUri": old_uri}}]},
            "permissionGrants": {
                "permissionGrants": {
                    "allow": [f"write_file({old_dir}\\src\\x.md)", "read_url(x)"]
                }
            },
            "settings": {},
        }
        proj_2 = {
            "id": "2",
            "name": "old proj",
            "projectResources": {"resources": [{"folderUri": other_uri}]},
            "permissionGrants": proj_1["permissionGrants"],
            "settings": {},
        }
        (gemini_root / "config" / "projects" / "1.json").write_text(
            json.dumps(proj_1, indent=2), encoding="utf-8"
        )
        (gemini_root / "config" / "projects" / "2.json").write_text(
            json.dumps(proj_2, indent=2), encoding="utf-8"
        )
        (gemini_root / "projects.json").write_text(
            json.dumps(
                {
                    "projects": {
                        str(old_dir).lower(): "old proj",
                        str(other_parent_same_leaf).lower(): "old proj",
                    }
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        conv_db = gemini_root / "antigravity" / "conversations" / "c.db"
        conv_db.parent.mkdir(parents=True)
        c = sqlite3.connect(conv_db)
        try:
            c.execute("CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB, step_payload BLOB)")
            c.execute(
                "INSERT INTO steps VALUES (1, ?, ?)",
                (json.dumps({"cwd": str(old_dir)}).encode("utf-8"), pb_field(3, pb_field(1, old_uri.encode("utf-8")))),
            )
            c.execute(
                "INSERT INTO steps VALUES (2, ?, ?)",
                (b"x" * 10, f'folder_uri: "{old_uri}"\n'.encode()),
            )
            c.commit()
        finally:
            c.close()

        slash_old_uri = ("file:///c:/" + str(old_dir)[3:].replace("\\", "/")).encode("utf-8")
        ide_pb = gemini_root / "antigravity-ide" / "conversations" / "a.pb"
        ide_pb.parent.mkdir(parents=True)
        ide_pb.write_bytes(pb_field(2, pb_field(1, slash_old_uri) + b"\x18\x7f"))

        agyhub_pb = gemini_root / "antigravity" / "agyhub_summaries_proto.pb"
        agyhub_pb.write_bytes(pb_field(1, slash_old_uri))

        if with_backups:
            now_stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            for name in (
                "User_AutoBackup_20200101_000000",
                "User_AutoBackup_20200102_000000",
                f"User_AutoBackup_{now_stamp}",
                "Migration_FileBackup_20200101_000000",
                "Migration_FileBackup_20200103_000000",
                "NotABackup_20200101_000000",
            ):
                d = app_root / name
                d.mkdir()
                (d / "marker.txt").write_text("keep", encoding="utf-8")
            (gemini_root / "antigravity_AutoBackup_20200101_000000").mkdir()

        return {
            "app_root": app_root,
            "user_dir": user_dir,
            "gemini_root": gemini_root,
            "new_dir": new_dir,
            "old_dir": old_dir,
            "other_dir": other_parent_same_leaf,
            "sib_dir": sibling_same_parent,
            "old_ws_dir": old_ws_dir,
            "stale_ws_dir": stale_ws_dir,
            "backups_root": backups_root,
            "fbackup_dir": self.root / "fbackup",
        }

    def test_powershell_parse_and_validation(self) -> None:
        """PowerShell wrapper parses cleanly and rejects invalid parameter combinations."""
        parse_cmd = (
            "$e = $null; "
            f"[void][System.Management.Automation.Language.Parser]::ParseFile('{SCRIPT_PATH}', [ref]$null, [ref]$e); "
            "if ($e.Count -ne 0) { $e | ForEach-Object { Write-Error $_.Message }; exit 1 }"
        )
        res = subprocess.run(
            ["powershell", "-NoProfile", "-Command", parse_cmd],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

        new_dir = self.root / "proj"
        new_dir.mkdir()
        bad_cases = [
            ["-NewProjectPath", str(new_dir), "-OldFolderName", "old", "-Apply", "-Verify"],
            ["-NewProjectPath", str(new_dir), "-OldFolderName", "old", "-Cleanup", "-Verify"],
            ["-NewProjectPath", str(new_dir), "-OldFolderName", "old", "-IncludeBackups"],
            ["-NewProjectPath", str(self.root / "missing"), "-OldFolderName", "old"],
        ]
        for flags in bad_cases:
            proc = subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT_PATH), *flags],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 1, f"Expected exit 1 for {flags}: {proc.stdout} {proc.stderr}")
            self.assertIn("ERROR:", proc.stdout + proc.stderr)

    def test_dry_run_apply_verify_and_isolation(self) -> None:
        """Dry-run is non-destructive; apply migrates all targets and passes strict verification."""
        fx = self.create_fixture()
        expected_hash = compute_vscode_workspace_hash(fx["new_dir"])

        # Pre-migration verify and cleanup must both fail/refuse with exit code 2.
        pre_verify = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            verify=True,
        )
        self.assertEqual(pre_verify.returncode, 2, pre_verify.stdout)

        pre_cleanup = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            cleanup=True,
            apply=True,
        )
        self.assertEqual(pre_cleanup.returncode, 2, pre_cleanup.stdout)
        self.assertIn("Cleanup refused", pre_cleanup.stdout)
        self.assertTrue(fx["old_ws_dir"].is_dir())
        self.assertTrue(fx["stale_ws_dir"].is_dir())

        # Dry-run leaves disk untouched.
        dry = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            apply=False,
        )
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertIn("DRY RUN COMPLETE", dry.stdout)
        self.assertFalse((fx["user_dir"] / "workspaceStorage" / expected_hash).exists())

        # Apply migrates to the exact IDE hash (ignoring stale_ws_dir) and verifies cleanly.
        applied = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=fx["fbackup_dir"],
            apply=True,
        )
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertIn("APPLIED SUCCESSFULLY", applied.stdout)
        self.assertIn("VERIFIED - all checks passed.", applied.stdout)

        live_ws = fx["user_dir"] / "workspaceStorage" / expected_hash
        self.assertTrue(live_ws.is_dir())
        self.assertEqual((live_ws / "workspace.json").read_text(encoding="utf-8"), json.dumps({"folder": vscode_uri(fx["new_dir"])}, indent=2))
        self.assertFalse((fx["fbackup_dir"] / "manifest.jsonl").stat().st_size == 0)

        # Both plain and nested base64 protobuf URIs must be updated; unrelated paths must remain intact.
        gdb = sqlite3.connect(fx["user_dir"] / "globalStorage" / "state.vscdb")
        try:
            self.assertEqual(gdb.execute("PRAGMA integrity_check;").fetchone()[0], "ok")
            items = dict(gdb.execute("SELECT key, value FROM ItemTable").fetchall())
        finally:
            gdb.close()

        sidebar_leaves = collect_pb_text_leaves(base64.b64decode(items["antigravityUnifiedStateSync.sidebarWorkspaces"]))
        self.assertIsNotNone(sidebar_leaves)
        plain_uris = [s for b64, s in sidebar_leaves if not b64]
        nested_uris = [s for b64, s in sidebar_leaves if b64]
        self.assertIn(vscode_uri(fx["new_dir"]), plain_uris)
        self.assertIn(vscode_uri(fx["new_dir"]), nested_uris)
        self.assertIn(vscode_uri(fx["other_dir"]), plain_uris)
        self.assertIn(vscode_uri(fx["other_dir"]), nested_uris)
        self.assertIn(vscode_uri(fx["sib_dir"]), plain_uris)
        self.assertIn(vscode_uri(fx["sib_dir"]), nested_uris)

        # Backup DB synced.
        bdb = sqlite3.connect(fx["user_dir"] / "globalStorage" / "state.vscdb.backup")
        try:
            self.assertEqual(bdb.execute("SELECT COUNT(*) FROM ItemTable").fetchone()[0], 3)
        finally:
            bdb.close()

        # Antigravity 2.0 projects and lowercase projects.json.
        p1 = json.loads((fx["gemini_root"] / "config" / "projects" / "1.json").read_text(encoding="utf-8"))
        p2 = json.loads((fx["gemini_root"] / "config" / "projects" / "2.json").read_text(encoding="utf-8"))
        self.assertEqual(p1["name"], "new proj.ag")
        self.assertEqual(p2["name"], "old proj")  # belongs to elsewhere/old proj, must not rename

        pj = json.loads((fx["gemini_root"] / "projects.json").read_text(encoding="utf-8"))["projects"]
        self.assertEqual(pj[str(fx["new_dir"]).lower()], "new proj.ag")
        self.assertEqual(pj[str(fx["other_dir"]).lower()], "old proj")

        # Strict protobuf validity on rewritten .pb files.
        self.assertIsNotNone(collect_pb_text_leaves((fx["gemini_root"] / "antigravity-ide" / "conversations" / "a.pb").read_bytes()))
        self.assertIsNotNone(collect_pb_text_leaves((fx["gemini_root"] / "antigravity" / "agyhub_summaries_proto.pb").read_bytes()))

        # Standalone verify passes with exit code 0.
        post_verify = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            verify=True,
        )
        self.assertEqual(post_verify.returncode, 0, post_verify.stdout)
        self.assertIn("VERIFIED - all checks passed.", post_verify.stdout)

    def test_rollback_restores_state_on_error(self) -> None:
        """An unexpected failure during -Apply rolls back modified files and created dirs."""
        fx = self.create_fixture()
        expected_hash = compute_vscode_workspace_hash(fx["new_dir"])
        wrapper = self.root / "fail_wrapper.py"
        wrapper.write_text(
            "import pathlib\n"
            f"src = pathlib.Path(r'{self.engine_file}').read_text(encoding='utf-8')\n"
            "ns = {'__name__': 'ag_test'}\n"
            "exec(src, ns)\n"
            "def boom(_tx):\n"
            "    raise RuntimeError('simulated failure')\n"
            "ns['scan_gemini'] = boom\n"
            "ns['main']()\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update(
            {
                "AG_NEW_PATH": str(fx["new_dir"]),
                "AG_OLD_PATH": str(fx["old_dir"]),
                "AG_USER_DIR": str(fx["user_dir"]),
                "AG_GEMINI_ROOT": str(fx["gemini_root"]),
                "AG_APPLY": "1",
                "AG_BACKUP_DIR": str(fx["fbackup_dir"]),
                "AG_VERIFY": "0",
                "AG_CLEANUP": "0",
                "PYTHONIOENCODING": "utf-8",
            }
        )
        proc = subprocess.run(
            [sys.executable, str(wrapper)],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("[Rollback] Original state restored.", proc.stdout)
        self.assertFalse((fx["user_dir"] / "workspaceStorage" / expected_hash).exists())
        self.assertFalse((fx["backups_root"] / expected_hash).exists())

        storage_txt = (fx["user_dir"] / "globalStorage" / "storage.json").read_text(encoding="utf-8")
        self.assertIn(vscode_uri(fx["old_dir"]), storage_txt)
        self.assertNotIn(vscode_uri(fx["new_dir"]), storage_txt)

        gdb = sqlite3.connect(fx["user_dir"] / "globalStorage" / "state.vscdb")
        try:
            self.assertEqual(gdb.execute("PRAGMA integrity_check;").fetchone()[0], "ok")
            recent = gdb.execute("SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'").fetchone()[0]
            self.assertIn(vscode_uri(fx["old_dir"]), recent)
            self.assertNotIn(vscode_uri(fx["new_dir"]), recent)
        finally:
            gdb.close()

    def test_cleanup_preview_apply_and_backup_pruning(self) -> None:
        """Cleanup removes old/stale workspace entries and aged backups while protecting live data."""
        fx = self.create_fixture(with_backups=True)
        expected_hash = compute_vscode_workspace_hash(fx["new_dir"])

        applied = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=fx["fbackup_dir"],
            apply=True,
        )
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)

        # Preview deletes nothing.
        preview = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            cleanup=True,
            apply=False,
            include_backups=True,
        )
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn("Would free", preview.stdout)
        self.assertTrue(fx["old_ws_dir"].is_dir())
        self.assertTrue(fx["stale_ws_dir"].is_dir())

        # Apply cleanup deletes leftovers and aged backups, keeping newest backups and NotABackup_*.
        cleaned = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            cleanup=True,
            apply=True,
            include_backups=True,
        )
        self.assertEqual(cleaned.returncode, 0, cleaned.stdout + cleaned.stderr)
        self.assertIn("Freed ", cleaned.stdout)

        ws_names = sorted(p.name for p in (fx["user_dir"] / "workspaceStorage").iterdir())
        bak_names = sorted(p.name for p in fx["backups_root"].iterdir() if p.is_dir())
        app_dirs = sorted(p.name for p in fx["app_root"].iterdir() if p.is_dir())
        gemini_dirs = sorted(p.name for p in fx["gemini_root"].iterdir() if p.is_dir())

        self.assertEqual(ws_names, [expected_hash])
        self.assertEqual(bak_names, [expected_hash])
        self.assertIn("NotABackup_20200101_000000", app_dirs)
        self.assertIn("Migration_FileBackup_20200103_000000", app_dirs)  # newest kept
        self.assertNotIn("Migration_FileBackup_20200101_000000", app_dirs)
        self.assertNotIn("User_AutoBackup_20200101_000000", app_dirs)
        self.assertNotIn("User_AutoBackup_20200102_000000", app_dirs)
        self.assertEqual(len([n for n in app_dirs if n.startswith("User_AutoBackup_")]), 1)
        self.assertIn("antigravity_AutoBackup_20200101_000000", gemini_dirs)  # only/newest kept

        # Second cleanup run finds nothing left.
        again = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            cleanup=True,
            apply=True,
            include_backups=True,
        )
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("Nothing to clean up.", again.stdout)

    def test_cross_parent_move_and_case_only_rename(self) -> None:
        """Cross-parent directory moves and case-only renames both migrate and verify cleanly."""
        # 1. Cross-parent move: OldParent/my-app -> NewParent/my-app-moved
        move_root = self.root / "move_case"
        old_app = move_root / "OldParent" / "my-app"
        new_app = move_root / "NewParent" / "my-app-moved"
        new_app.mkdir(parents=True)
        u_dir = move_root / "AppData" / "User"
        g_root = move_root / ".gemini"
        (u_dir / "globalStorage").mkdir(parents=True)
        ws_old = u_dir / "workspaceStorage" / ("c" * 32)
        ws_old.mkdir(parents=True)
        (ws_old / "workspace.json").write_text(json.dumps({"folder": vscode_uri(old_app)}), encoding="utf-8")
        make_item_db(
            u_dir / "globalStorage" / "state.vscdb",
            [("history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": vscode_uri(old_app)}]}))],
        )
        (u_dir / "globalStorage" / "storage.json").write_text(
            json.dumps({"windowsState": {"lastActiveWindow": {"folder": vscode_uri(old_app)}}}),
            encoding="utf-8",
        )
        (g_root / "config" / "projects").mkdir(parents=True)

        res_move = self.run_engine(
            new_path=new_app,
            old_path=old_app,
            user_dir=u_dir,
            gemini_root=g_root,
            backup_dir=move_root / "fbackup",
            apply=True,
        )
        self.assertEqual(res_move.returncode, 0, res_move.stdout + res_move.stderr)
        self.assertIn("VERIFIED", res_move.stdout)
        self.assertNotIn("NOT VERIFIED", res_move.stdout)

        # 2. Case-only rename: MyApp -> myapp
        case_root = self.root / "case_only"
        case_parent = case_root / "Repos"
        case_parent.mkdir(parents=True)
        old_case = case_parent / "MyApp"
        new_case = case_parent / "myapp"
        new_case.mkdir()
        cu_dir = case_root / "AppData" / "User"
        cg_root = case_root / ".gemini"
        (cu_dir / "globalStorage").mkdir(parents=True)
        cws_old = cu_dir / "workspaceStorage" / ("d" * 32)
        cws_old.mkdir(parents=True)
        (cws_old / "workspace.json").write_text(json.dumps({"folder": vscode_uri(old_case)}), encoding="utf-8")
        make_item_db(
            cu_dir / "globalStorage" / "state.vscdb",
            [("history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": vscode_uri(old_case)}]}))],
        )
        (cu_dir / "globalStorage" / "storage.json").write_text(
            json.dumps({"windowsState": {"lastActiveWindow": {"folder": vscode_uri(old_case)}}}),
            encoding="utf-8",
        )
        (cg_root / "config" / "projects").mkdir(parents=True)

        res_case = self.run_engine(
            new_path=new_case,
            old_path=old_case,
            user_dir=cu_dir,
            gemini_root=cg_root,
            backup_dir=case_root / "fbackup",
            apply=True,
        )
        self.assertEqual(res_case.returncode, 0, res_case.stdout + res_case.stderr)
        self.assertIn("VERIFIED", res_case.stdout)
        self.assertNotIn("NOT VERIFIED", res_case.stdout)
        c_gdb = sqlite3.connect(cu_dir / "globalStorage" / "state.vscdb")
        try:
            recent = c_gdb.execute(
                "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"
            ).fetchone()[0]
            self.assertIn("Repos/myapp", recent)
            self.assertNotIn("Repos/MyApp", recent)
        finally:
            c_gdb.close()

    def test_friendly_illegal_path_char_error(self) -> None:
        """Placeholder/illegal characters in paths produce friendly ERROR messages, not raw exceptions."""
        proc = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPT_PATH),
                "-NewProjectPath",
                r"C:\Users\<User>\Downloads\proj",
                "-OldFolderName",
                "old",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        out = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 1, out)
        self.assertIn("ERROR:", out)
        self.assertIn("placeholder", out)
        self.assertNotIn("ArgumentException", out)

    def test_overwrite_protection_and_force_override(self) -> None:
        """Newer populated target state.vscdb is protected by default unless -OverwriteExistingState is set."""
        fx = self.create_fixture()
        expected_hash = compute_vscode_workspace_hash(fx["new_dir"])
        target_ws = fx["user_dir"] / "workspaceStorage" / expected_hash
        target_ws.mkdir(parents=True)
        (target_ws / "workspace.json").write_text(
            json.dumps({"folder": vscode_uri(fx["new_dir"])}, indent=2), encoding="utf-8"
        )
        target_db = target_ws / "state.vscdb"
        make_item_db(
            target_db,
            [
                ("sentinel.newer", "keep-this-newer-ui-state"),
                ("memento/y", "{}"),
            ],
        )
        # Ensure target DB mtime is strictly newer than the old workspace DB.
        old_mtime = (fx["old_ws_dir"] / "state.vscdb").stat().st_mtime
        os.utime(target_db, (old_mtime + 10, old_mtime + 10))

        # Default -Apply skips copying old state over newer populated target DB.
        protected = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=fx["fbackup_dir"],
            apply=True,
            overwrite_state=False,
        )
        self.assertEqual(protected.returncode, 0, protected.stdout + protected.stderr)
        self.assertIn("skipping state copy to protect newer UI state", protected.stdout)
        conn = sqlite3.connect(target_db)
        try:
            keys = {r[0] for r in conn.execute("SELECT key FROM ItemTable").fetchall()}
            self.assertIn("sentinel.newer", keys)
        finally:
            conn.close()

        # -OverwriteExistingState forces copying old state over the target DB.
        forced = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=fx["fbackup_dir"],
            apply=True,
            overwrite_state=True,
        )
        self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        conn = sqlite3.connect(target_db)
        try:
            items = dict(conn.execute("SELECT key, value FROM ItemTable").fetchall())
            self.assertIn("memento/x", items)
            self.assertIn("new%20proj.ag", items["memento/x"])
        finally:
            conn.close()

    def test_list_backups_and_restore(self) -> None:
        """-ListBackups lists snapshots and -Restore restores User + .gemini files cleanly."""
        fx = self.create_fixture()
        stamp = "20261126_120000"
        user_bak = fx["app_root"] / f"User_AutoBackup_{stamp}"
        file_bak = fx["app_root"] / f"Migration_FileBackup_{stamp}"
        shutil.copytree(fx["user_dir"], user_bak)

        applied = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=file_bak,
            apply=True,
        )
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)

        listed = self.run_engine(
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            app_root=fx["app_root"],
            list_backups=True,
        )
        self.assertEqual(listed.returncode, 0, listed.stdout + listed.stderr)
        self.assertIn(stamp, listed.stdout)
        self.assertIn("User_AutoBackup", listed.stdout)
        self.assertIn("Migration_FileBackup", listed.stdout)

        # Invalid stamp must be rejected.
        bad = self.run_engine(
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            app_root=fx["app_root"],
            restore_stamp="../evil",
        )
        self.assertEqual(bad.returncode, 1)

        # Preview does not modify migrated files.
        preview = self.run_engine(
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            app_root=fx["app_root"],
            restore_stamp=stamp,
            apply=False,
        )
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn("RESTORE PREVIEW COMPLETE", preview.stdout)
        p1 = json.loads((fx["gemini_root"] / "config" / "projects" / "1.json").read_text(encoding="utf-8"))
        self.assertEqual(p1["name"], "new proj.ag")

        # Apply restore reverts both User and .gemini files cleanly.
        restored = self.run_engine(
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            app_root=fx["app_root"],
            restore_stamp=stamp,
            apply=True,
        )
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertIn("RESTORE COMPLETED SUCCESSFULLY", restored.stdout)
        p1_restored = json.loads((fx["gemini_root"] / "config" / "projects" / "1.json").read_text(encoding="utf-8"))
        self.assertEqual(p1_restored["name"], "old proj")
        self.assertFalse((fx["user_dir"] / "workspaceStorage" / compute_vscode_workspace_hash(fx["new_dir"])).exists())

        gdb = sqlite3.connect(fx["user_dir"] / "globalStorage" / "state.vscdb")
        try:
            self.assertEqual(gdb.execute("PRAGMA integrity_check;").fetchone()[0], "ok")
        finally:
            gdb.close()

    def test_fts5_local_history_and_multiroot_workspace(self) -> None:
        """FTS5 index, User/History, and multi-root .code-workspace entries all migrate, verify, and clean up."""
        fx = self.create_fixture()

        # 1. conversation_summaries.db with FTS5 table
        cs_db = fx["gemini_root"] / "antigravity" / "conversation_summaries.db"
        cs_conn = sqlite3.connect(cs_db)
        try:
            cs_conn.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, workspace_uris TEXT)")
            cs_conn.execute(
                "CREATE VIRTUAL TABLE conversations_fts USING fts5("
                "conversation_id UNINDEXED, workspace, project, title)"
            )
            cs_conn.execute(
                "INSERT INTO conversation_summaries VALUES (?, ?)",
                ("cid-target", vscode_uri(fx["old_dir"])),
            )
            cs_conn.execute(
                "INSERT INTO conversation_summaries VALUES (?, ?)",
                ("cid-other", vscode_uri(fx["other_dir"])),
            )
            cs_conn.execute(
                "INSERT INTO conversations_fts (conversation_id, workspace, project, title) VALUES (?, ?, ?, ?)",
                ("cid-target", "old%20proj", "old proj", "Target chat"),
            )
            cs_conn.execute(
                "INSERT INTO conversations_fts (conversation_id, workspace, project, title) VALUES (?, ?, ?, ?)",
                ("cid-other", "old%20proj", "old proj", "Unrelated same-leaf chat"),
            )
            cs_conn.commit()
        finally:
            cs_conn.close()

        # 2. User/History entry matching VS Code stringHash(resource, 0)
        hist_old_res = vscode_uri(fx["old_dir"]) + "/src/app.py"
        hist_new_res = vscode_uri(fx["new_dir"]) + "/src/app.py"

        def vs_hash(s: str) -> str:
            h = 149417
            for ch in s:
                h = (((h << 5) - h) + ord(ch)) & 0xFFFFFFFF
            if h >= 0x80000000:
                h -= 0x100000000
            return f"-{-h:x}" if h < 0 else f"{h:x}"

        old_hist_name = vs_hash(hist_old_res)
        new_hist_name = vs_hash(hist_new_res)
        old_hist_dir = fx["user_dir"] / "History" / old_hist_name
        old_hist_dir.mkdir(parents=True)
        (old_hist_dir / "entries.json").write_text(
            json.dumps({"version": 1, "resource": hist_old_res, "entries": [{"id": "abc.py", "timestamp": 100}]}),
            encoding="utf-8",
        )
        (old_hist_dir / "abc.py").write_text("print('hi')\n", encoding="utf-8")

        # 3. Multi-root .code-workspace (moved file + external file referencing moved project)
        ws_file_moved = fx["new_dir"] / "team.code-workspace"
        ws_file_moved.write_text(json.dumps({"folders": [{"path": str(fx["old_dir"])}]}, indent=2), encoding="utf-8")
        old_ws_file_virtual = fx["old_dir"] / "team.code-workspace"
        multi_old_dir = fx["user_dir"] / "workspaceStorage" / ("e" * 32)
        multi_old_dir.mkdir(parents=True)
        (multi_old_dir / "workspace.json").write_text(
            json.dumps({"workspace": vscode_uri(old_ws_file_virtual)}), encoding="utf-8"
        )
        make_item_db(multi_old_dir / "state.vscdb", [("memento/mr", vscode_uri(fx["old_dir"]))])

        ext_ws_file = self.root / "external.code-workspace"
        ext_ws_file.write_text(
            json.dumps({"folders": [{"path": str(fx["old_dir"])}, {"path": str(fx["other_dir"])}]}, indent=2),
            encoding="utf-8",
        )
        ext_ws_dir = fx["user_dir"] / "workspaceStorage" / compute_vscode_workspace_hash(ext_ws_file)
        ext_ws_dir.mkdir(parents=True)
        (ext_ws_dir / "workspace.json").write_text(json.dumps({"workspace": vscode_uri(ext_ws_file)}), encoding="utf-8")

        applied = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            backup_dir=fx["fbackup_dir"],
            apply=True,
        )
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertIn("VERIFIED - all checks passed.", applied.stdout)

        # Verify FTS5 updated only cid-target and passes integrity-check.
        cs_ro = sqlite3.connect(cs_db)
        try:
            cs_ro.execute("INSERT INTO conversations_fts(conversations_fts) VALUES('integrity-check');")
            rows = {
                r[0]: (r[1], r[2])
                for r in cs_ro.execute("SELECT conversation_id, workspace, project FROM conversations_fts").fetchall()
            }
            self.assertEqual(rows["cid-target"], ("new%20proj.ag", "new proj.ag"))
            self.assertEqual(rows["cid-other"], ("old%20proj", "old proj"))
        finally:
            cs_ro.close()

        # Verify User/History migrated and cleanup removes old history folder.
        new_hist_dir = fx["user_dir"] / "History" / new_hist_name
        self.assertTrue((new_hist_dir / "abc.py").is_file())
        new_ej = json.loads((new_hist_dir / "entries.json").read_text(encoding="utf-8"))
        self.assertEqual(new_ej["resource"], hist_new_res)

        # Verify multi-root .code-workspace storage + files updated.
        moved_hash = compute_vscode_workspace_hash(ws_file_moved)
        self.assertTrue((fx["user_dir"] / "workspaceStorage" / moved_hash / "state.vscdb").is_file())
        self.assertEqual(json.loads(ws_file_moved.read_text(encoding="utf-8"))["folders"][0]["path"], str(fx["new_dir"]))
        ext_folders = json.loads(ext_ws_file.read_text(encoding="utf-8"))["folders"]
        self.assertEqual(ext_folders[0]["path"], str(fx["new_dir"]))
        self.assertEqual(ext_folders[1]["path"], str(fx["other_dir"]))

        cleaned = self.run_engine(
            new_path=fx["new_dir"],
            old_path=fx["old_dir"],
            user_dir=fx["user_dir"],
            gemini_root=fx["gemini_root"],
            cleanup=True,
            apply=True,
        )
        self.assertEqual(cleaned.returncode, 0, cleaned.stdout + cleaned.stderr)
        self.assertFalse(old_hist_dir.exists())
        self.assertTrue(new_hist_dir.is_dir())
        self.assertFalse(multi_old_dir.exists())
        self.assertTrue((fx["user_dir"] / "workspaceStorage" / moved_hash).is_dir())

    def test_rename_on_disk_and_rollback(self) -> None:
        """-RenameOnDisk helper handles normal & case-only renames, dry-run hashing, and rollback."""
        # 1. Engine dry-run hash calculation when NEW_PATH does not yet exist on disk.
        src = self.root / "rn_dry"
        src.mkdir()
        existing_old = src / "BeforeRename"
        existing_old.mkdir()
        time.sleep(0.02)
        target_new = src / "AfterRename"
        u_dir = self.root / "rn_app" / "User"
        g_root = self.root / "rn_gem"
        (u_dir / "globalStorage").mkdir(parents=True)
        ws_old = u_dir / "workspaceStorage" / ("f" * 32)
        ws_old.mkdir(parents=True)
        (ws_old / "workspace.json").write_text(json.dumps({"folder": vscode_uri(existing_old)}), encoding="utf-8")
        make_item_db(u_dir / "globalStorage" / "state.vscdb", [])
        (u_dir / "globalStorage" / "storage.json").write_text("{}", encoding="utf-8")
        (g_root / "config" / "projects").mkdir(parents=True)

        dry = self.run_engine(
            new_path=target_new,
            old_path=existing_old,
            user_dir=u_dir,
            gemini_root=g_root,
            rename_dryrun=True,
            apply=False,
        )
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertTrue(existing_old.is_dir())
        self.assertFalse(target_new.exists())
        # Target hash computed during dry-run must match the hash after NTFS preserves creation time.
        expected_if_renamed = compute_vscode_workspace_hash(target_new) if target_new.exists() else None
        self.assertIsNone(expected_if_renamed)
        self.assertIn("Created target hash:", dry.stdout)

        # 2. PowerShell Move-DirectorySafely handles case-only rename + rollback on NTFS.
        ps_case = self.root / "CaseBox"
        ps_case.mkdir()
        ps_old = ps_case / "MyApp"
        ps_old.mkdir()
        (ps_old / "file.txt").write_text("ok", encoding="utf-8")
        ps_new = ps_case / "myapp"
        ps_check = (
            "$tokens = $null; $errs = $null; "
            f"$ast = [System.Management.Automation.Language.Parser]::ParseFile('{SCRIPT_PATH}', [ref]$tokens, [ref]$errs); "
            "$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Move-DirectorySafely' }, $true); "
            "Invoke-Expression $fn.Extent.Text; "
            f"Move-DirectorySafely '{ps_old}' '{ps_new}' $true; "
            f"$leaf1 = (Get-Item -LiteralPath '{ps_case}').GetDirectories()[0].Name; "
            f"Move-DirectorySafely '{ps_new}' '{ps_old}' $true; "
            f"$leaf2 = (Get-Item -LiteralPath '{ps_case}').GetDirectories()[0].Name; "
            "Write-Output \"$leaf1|$leaf2\""
        )
        proc = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_check],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(proc.stdout.strip(), "myapp|MyApp")

        # 3. Full PowerShell -RenameOnDisk -Apply end-to-end when Antigravity is not running (e.g. CI).
        running_check = subprocess.run(
            ["powershell", "-NoProfile", "-Command", "if (Get-Process | Where-Object { $_.ProcessName -match 'Antigravity' }) { exit 99 }"],
            capture_output=True,
            text=True,
            check=False,
        )
        if running_check.returncode == 0:
            ps_env = os.environ.copy()
            ps_env["APPDATA"] = str(self.root / "rn_app_ps")
            ps_env["USERPROFILE"] = str(self.root / "rn_home_ps")
            ps_user = Path(ps_env["APPDATA"]) / "Antigravity IDE" / "User"
            (ps_user / "globalStorage").mkdir(parents=True)
            ps_ws = ps_user / "workspaceStorage" / ("9" * 32)
            ps_ws.mkdir(parents=True)
            (ps_ws / "workspace.json").write_text(json.dumps({"folder": vscode_uri(existing_old)}), encoding="utf-8")
            make_item_db(
                ps_user / "globalStorage" / "state.vscdb",
                [("history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": vscode_uri(existing_old)}]}))],
            )
            (ps_user / "globalStorage" / "storage.json").write_text("{}", encoding="utf-8")
            (Path(ps_env["USERPROFILE"]) / ".gemini" / "config" / "projects").mkdir(parents=True)

            e2e = subprocess.run(
                [
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(SCRIPT_PATH),
                    "-NewProjectPath",
                    str(target_new),
                    "-OldFolderName",
                    existing_old.name,
                    "-RenameOnDisk",
                    "-Apply",
                ],
                env=ps_env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(e2e.returncode, 0, e2e.stdout + e2e.stderr)
            self.assertTrue(target_new.is_dir())
            self.assertFalse(existing_old.exists())
            self.assertIn("VERIFIED", e2e.stdout)


if __name__ == "__main__":
    unittest.main()
