"""Cross-platform and native POSIX tests for the Linux and macOS migration scripts."""

import ast
import base64
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parent.parent
LINUX_SCRIPT = REPO_ROOT / "migrate-antigravity-workspace-linux.sh"
MACOS_SCRIPT = REPO_ROOT / "migrate-antigravity-workspace-macos.sh"


def extract_shell_python_engine(script_path: Path) -> str:
    """Extract the embedded Python engine from a bash migration script."""
    raw = script_path.read_text(encoding="utf-8")
    marker = "cat <<'__AG_MIGRATE_PY__' > \"$TEMP_PY\"\n"
    start = raw.index(marker) + len(marker)
    end = raw.index("\n__AG_MIGRATE_PY__", start)
    return raw[start:end]


def load_posix_engine_namespace(script_path: Path, new_path: str, old_path: str) -> dict[str, object]:
    """Load pure helper functions from a POSIX script engine into an isolated namespace."""
    src = extract_shell_python_engine(script_path)
    src = src.replace('if os.name != "posix":\n    sys.exit("This script supports POSIX systems only.")', "")
    src = src.replace("NEW_PATH = Path(os.path.realpath(NEW_PATH_RAW)) if NEW_PATH_RAW else None", "NEW_PATH = PurePosixPath(NEW_PATH_RAW)")
    old_env = {
        k: os.environ.get(k)
        for k in ("AG_NEW_PATH", "AG_OLD_PATH", "AG_APP_ROOT", "AG_USER_DIR", "AG_GEMINI_ROOT", "AG_APPLY")
    }
    os.environ.update(
        {
            "AG_NEW_PATH": new_path,
            "AG_OLD_PATH": old_path,
            "AG_APP_ROOT": "/tmp/ag_app",
            "AG_USER_DIR": "/tmp/ag_app/User",
            "AG_GEMINI_ROOT": "/tmp/.gemini",
            "AG_APPLY": "0",
        }
    )
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            mod_path = Path(tmpdir) / "ag_posix_unit.py"
            mod_path.write_text(src, encoding="utf-8")
            spec = importlib.util.spec_from_file_location("ag_posix_unit", mod_path)
            assert spec is not None and spec.loader is not None
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            mod.set_old_path(old_path)
            return vars(mod)
    finally:
        for k, v in old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


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


def pb_field(field_num: int, payload: bytes) -> bytes:
    """Build a length-delimited Protobuf field."""
    return encode_varint((field_num << 3) | 2) + encode_varint(len(payload)) + payload


def posix_uri(path: str) -> str:
    """Build a canonical VS Code file:// URI for a POSIX path."""
    return "file://" + quote(path, safe="/")


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
        inner = pb_field(4, pb_field(1, ub) + b"\x10\x01") if idx % 2 == 0 else pb_field(1, ub)
        b64_inner = base64.b64encode(inner)
        top.extend(pb_field(1, pb_field(1, ub) + pb_field(2, b64_inner)))
    return base64.b64encode(bytes(top)).decode("ascii")


def vs_string_hash(s: str) -> str:
    """Compute VS Code's stringHash(s, 0) used for User/History folder names."""
    h = 149417
    for ch in s:
        h = (((h << 5) - h) + ord(ch)) & 0xFFFFFFFF
    if h >= 0x80000000:
        h -= 0x100000000
    return f"-{-h:x}" if h < 0 else f"{h:x}"


class PosixScriptStaticTests(unittest.TestCase):
    """Cross-platform checks for Linux and macOS bash scripts and embedded Python engines."""

    def test_shell_scripts_structure_and_python_ast(self) -> None:
        """Both scripts exist, use LF line endings, have bash shebangs, and parse cleanly."""
        for script in (LINUX_SCRIPT, MACOS_SCRIPT):
            raw_bytes = script.read_bytes()
            self.assertNotIn(b"\r", raw_bytes, f"{script.name} must use LF line endings only")
            text = raw_bytes.decode("utf-8")
            self.assertTrue(text.startswith("#!/usr/bin/env bash\n"), f"{script.name} missing bash shebang")
            engine = extract_shell_python_engine(script)
            ast.parse(engine)

    def test_posix_path_matching_and_protobuf_transforms(self) -> None:
        """POSIX path matching isolates prefixes/siblings and rewrites nested base64 protobufs."""
        old_p = "/home/user/src/old proj"
        new_p = "/home/user/src/new proj.ag"

        linux_ns = load_posix_engine_namespace(LINUX_SCRIPT, new_p, old_p)
        macos_ns = load_posix_engine_namespace(MACOS_SCRIPT, new_p, old_p)

        for label, ns in (("linux", linux_ns), ("macos", macos_ns)):
            transform_string = ns["transform_string"]
            collect_leaves = ns["collect_leaves"]
            assert callable(transform_string)
            assert callable(collect_leaves)

            # Raw path & file:// URI rewrite
            out_raw, ch_raw = transform_string(f'cwd="{old_p}/sub"')
            self.assertTrue(ch_raw, label)
            self.assertEqual(out_raw, f'cwd="{new_p}/sub"')

            out_uri, ch_uri = transform_string(posix_uri(old_p) + "/main.py")
            self.assertTrue(ch_uri, label)
            self.assertEqual(out_uri, posix_uri(new_p) + "/main.py")

            # Nested prefix & sibling paths must NOT match
            for untouched in (
                f"/backup{old_p}",
                f"{old_p}2",
                "/other/home/user/src/old proj",
            ):
                res, changed = transform_string(untouched)
                self.assertFalse(changed, f"{label} falsely matched {untouched} -> {res}")

            # Recursive + base64 protobuf rewriting
            sidebar = build_sidebar_value([posix_uri(old_p), posix_uri(f"/backup{old_p}")])
            new_sidebar, ch_sb = transform_string(sidebar)
            self.assertTrue(ch_sb, label)
            leaves = collect_leaves(base64.b64decode(new_sidebar))
            self.assertIsNotNone(leaves, label)
            assert isinstance(leaves, list)
            plain_uris = [s for b64, s in leaves if not b64]
            nested_uris = [s for b64, s in leaves if b64]
            self.assertIn(posix_uri(new_p), plain_uris)
            self.assertIn(posix_uri(new_p), nested_uris)
            self.assertIn(posix_uri(f"/backup{old_p}"), plain_uris)
            self.assertIn(posix_uri(f"/backup{old_p}"), nested_uris)

        # Linux is case-sensitive on normal paths, macOS is case-insensitive
        mixed = "/home/user/src/OLD PROJ"
        _, ch_lin = linux_ns["transform_string"](mixed)  # type: ignore[index]
        out_mac, ch_mac = macos_ns["transform_string"](mixed)  # type: ignore[index]
        self.assertFalse(ch_lin)
        self.assertTrue(ch_mac)
        self.assertEqual(out_mac, new_p)

        # projects.json lower_keys mode still matches lowercased paths even on Linux
        linux_s = linux_ns["S"]  # type: ignore[index]
        assert isinstance(linux_s, dict)
        linux_s["lower_keys"] = True
        try:
            out_pj, ch_pj = linux_ns["transform_string"](json.dumps({old_p.lower(): "old proj"}))  # type: ignore[index]
            self.assertTrue(ch_pj)
            self.assertEqual(json.loads(out_pj), {new_p.lower(): "new proj.ag"})
        finally:
            linux_s["lower_keys"] = False


class _NativePosixE2EMixin:
    """Shared end-to-end test runner for native Linux and macOS bash scripts."""

    script_path: Path
    platform_mode: str

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self._tmp.name))
        self.home = self.root / "home"
        self.home.mkdir()
        if self.platform_mode == "linux":
            self.xdg_config = self.root / "xdg_config"
            self.app_root = self.xdg_config / "Antigravity IDE"
        else:
            self.xdg_config = None
            self.app_root = self.home / "Library" / "Application Support" / "Antigravity IDE"
        self.user_dir = self.app_root / "User"
        self.gemini_root = self.home / ".gemini"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def compute_expected_hash(self, target: Path) -> str:
        st = os.stat(target)
        if self.platform_mode == "linux":
            salt = str(st.st_ino)
        else:
            bt_ms = st.st_birthtime_ns // 1_000_000 if hasattr(st, "st_birthtime_ns") else int(st.st_birthtime * 1000)
            salt = str(bt_ms)
        return hashlib.md5((str(target) + salt).encode("utf-8")).hexdigest()

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        if self.xdg_config is not None:
            env["XDG_CONFIG_HOME"] = str(self.xdg_config)
        return subprocess.run(
            ["bash", str(self.script_path), *args],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )

    def create_fixture(self) -> dict[str, Path]:
        src = self.root / "Source Code"
        src.mkdir()
        new_dir = src / "new proj.ag"
        new_dir.mkdir()
        old_dir = src / "old proj"
        other_dir = self.root / "elsewhere" / "old proj"
        other_dir.mkdir(parents=True)
        backup_prefix_dir = self.root / "backup_root" / str(old_dir).lstrip("/")
        backup_prefix_dir.mkdir(parents=True)

        old_uri = posix_uri(str(old_dir))
        new_uri = posix_uri(str(new_dir))
        other_uri = posix_uri(str(other_dir))
        pref_uri = posix_uri(str(backup_prefix_dir))

        old_hash = "a" * 32
        stale_hash = "b" * 32
        old_ws = self.user_dir / "workspaceStorage" / old_hash
        stale_ws = self.user_dir / "workspaceStorage" / stale_hash
        old_ws.mkdir(parents=True)
        stale_ws.mkdir(parents=True)

        (old_ws / "workspace.json").write_text(json.dumps({"folder": old_uri}), encoding="utf-8")
        (stale_ws / "workspace.json").write_text(json.dumps({"folder": new_uri}), encoding="utf-8")
        make_item_db(old_ws / "state.vscdb", [("memento/x", json.dumps({"folder": old_uri}))])
        make_item_db(stale_ws / "state.vscdb", [("memento/x", "{}")])

        global_dir = self.user_dir / "globalStorage"
        make_item_db(
            global_dir / "state.vscdb",
            [
                ("antigravityUnifiedStateSync.sidebarWorkspaces", build_sidebar_value([old_uri, other_uri, pref_uri])),
                ("history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": old_uri}, {"folderUri": other_uri}]})),
            ],
        )
        (global_dir / "storage.json").write_text(
            json.dumps({"windowsState": {"lastActiveWindow": {"folder": old_uri}}}),
            encoding="utf-8",
        )

        backups_root = self.app_root / "Backups"
        (backups_root / old_hash).mkdir(parents=True)
        (backups_root / "workspaces.json").write_text(json.dumps({"folderURIWorkspaces": [old_uri]}), encoding="utf-8")
        (backups_root / old_hash / "meta.json").write_text(json.dumps({"folder": old_uri}), encoding="utf-8")

        hist_old_res = old_uri + "/main.py"
        hist_old_dir = self.user_dir / "History" / vs_string_hash(hist_old_res)
        hist_old_dir.mkdir(parents=True)
        (hist_old_dir / "entries.json").write_text(
            json.dumps({"version": 1, "resource": hist_old_res, "entries": [{"id": "s1.py", "timestamp": 1}]}),
            encoding="utf-8",
        )
        (hist_old_dir / "s1.py").write_text("print(1)\n", encoding="utf-8")

        (self.gemini_root / "config" / "projects").mkdir(parents=True)
        (self.gemini_root / "config" / "projects" / "1.json").write_text(
            json.dumps(
                {
                    "id": "1",
                    "name": "old proj",
                    "projectResources": {"resources": [{"gitFolder": {"folderUri": old_uri}}]},
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        (self.gemini_root / "projects.json").write_text(
            json.dumps({"projects": {str(old_dir).lower(): "old proj", str(other_dir).lower(): "old proj"}}),
            encoding="utf-8",
        )

        antigrav_dir = self.gemini_root / "antigravity"
        (antigrav_dir / "conversations").mkdir(parents=True)
        cs_db = antigrav_dir / "conversation_summaries.db"
        cs = sqlite3.connect(cs_db)
        try:
            cs.execute("CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, workspace_uris TEXT)")
            cs.execute("CREATE VIRTUAL TABLE conversations_fts USING fts5(conversation_id UNINDEXED, workspace, project, title)")
            cs.execute("INSERT INTO conversation_summaries VALUES ('c1', ?)", (old_uri,))
            cs.execute("INSERT INTO conversations_fts (conversation_id, workspace, project, title) VALUES ('c1', 'old%20proj', 'old proj', 'T')")
            cs.commit()
        finally:
            cs.close()

        # Multi-root .code-workspace
        ws_file = new_dir / "team.code-workspace"
        ws_file.write_text(json.dumps({"folders": [{"path": str(old_dir)}]}, indent=2), encoding="utf-8")
        multi_old = self.user_dir / "workspaceStorage" / ("e" * 32)
        multi_old.mkdir(parents=True)
        (multi_old / "workspace.json").write_text(json.dumps({"workspace": old_uri + "/team.code-workspace"}), encoding="utf-8")
        make_item_db(multi_old / "state.vscdb", [("memento/mr", old_uri)])

        return {
            "new_dir": new_dir,
            "old_dir": old_dir,
            "other_dir": other_dir,
            "old_ws": old_ws,
            "stale_ws": stale_ws,
            "multi_old": multi_old,
            "hist_old_dir": hist_old_dir,
            "hist_new_res": new_uri + "/main.py",
            "ws_file": ws_file,
            "cs_db": cs_db,
        }

    def run_native_e2e_suite(self) -> None:
        # 1. Validation & friendly placeholder check
        help_res = self.run_cli("--help")
        self.assertEqual(help_res.returncode, 0, help_res.stderr)

        bad_ph = self.run_cli("--new-project-path", "/home/<User>/proj", "--old-folder-name", "old")
        self.assertEqual(bad_ph.returncode, 1)
        self.assertIn("placeholder", bad_ph.stderr)

        bad_combo = self.run_cli("--new-project-path", "/tmp", "--old-folder-name", "old", "--apply", "--verify")
        self.assertEqual(bad_combo.returncode, 1)

        # 2. Full fixture: pre-verify fails (2), cleanup refuses (2), dry-run (0), apply (0)
        fx = self.create_fixture()
        expected_hash = self.compute_expected_hash(fx["new_dir"])

        pre_v = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--verify")
        self.assertEqual(pre_v.returncode, 2, pre_v.stdout)

        pre_c = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--cleanup", "--apply")
        self.assertEqual(pre_c.returncode, 2, pre_c.stdout)
        self.assertTrue(fx["old_ws"].is_dir())

        dry = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name)
        self.assertEqual(dry.returncode, 0, dry.stdout + dry.stderr)
        self.assertFalse((self.user_dir / "workspaceStorage" / expected_hash).exists())

        app = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--apply")
        self.assertEqual(app.returncode, 0, app.stdout + app.stderr)
        self.assertIn("VERIFIED - all checks passed.", app.stdout)

        live_ws = self.user_dir / "workspaceStorage" / expected_hash
        self.assertTrue(live_ws.is_dir())
        self.assertEqual(
            json.loads((live_ws / "workspace.json").read_text(encoding="utf-8"))["folder"],
            posix_uri(str(fx["new_dir"])),
        )
        self.assertTrue((self.user_dir / "History" / vs_string_hash(fx["hist_new_res"]) / "s1.py").is_file())
        self.assertEqual(json.loads(fx["ws_file"].read_text(encoding="utf-8"))["folders"][0]["path"], str(fx["new_dir"]))

        # Verify FTS5 updated cleanly
        cs = sqlite3.connect(fx["cs_db"])
        try:
            cs.execute("INSERT INTO conversations_fts(conversations_fts) VALUES('integrity-check');")
            row = cs.execute("SELECT workspace, project FROM conversations_fts WHERE conversation_id='c1'").fetchone()
            self.assertEqual(row, ("new%20proj.ag", "new proj.ag"))
        finally:
            cs.close()

        # 3. Overwrite protection protects newer target state.vscdb
        new_db = live_ws / "state.vscdb"
        make_item_db(new_db, [("sentinel.newer", "keep"), ("memento/y", "{}")])
        old_mtime = (fx["old_ws"] / "state.vscdb").stat().st_mtime
        os.utime(new_db, (old_mtime + 10, old_mtime + 10))
        reapp = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--apply")
        self.assertEqual(reapp.returncode, 0, reapp.stdout + reapp.stderr)
        self.assertIn("skipping state copy", reapp.stdout)

        # 4. --list-backups & --restore (preview then apply), then re-apply and --cleanup
        listed = self.run_cli("--list-backups")
        self.assertEqual(listed.returncode, 0, listed.stdout + listed.stderr)
        m = re.search(r"(\d{8}_\d{6})\s+\|", listed.stdout)
        self.assertIsNotNone(m, listed.stdout)
        assert m is not None
        stamp = m.group(1)

        res_prev = self.run_cli("--restore", "--backup-stamp", stamp)
        self.assertEqual(res_prev.returncode, 0, res_prev.stdout + res_prev.stderr)
        self.assertTrue(live_ws.is_dir())

        res_app = self.run_cli("--restore", "--backup-stamp", stamp, "--apply")
        self.assertEqual(res_app.returncode, 0, res_app.stdout + res_app.stderr)
        self.assertFalse(live_ws.exists())

        # Re-apply and clean up leftovers
        reapp2 = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--apply")
        self.assertEqual(reapp2.returncode, 0, reapp2.stdout + reapp2.stderr)

        cln = self.run_cli("--new-project-path", str(fx["new_dir"]), "--old-folder-name", fx["old_dir"].name, "--cleanup", "--apply", "--include-backups")
        self.assertEqual(cln.returncode, 0, cln.stdout + cln.stderr)
        self.assertFalse(fx["old_ws"].exists())
        self.assertFalse(fx["stale_ws"].exists())
        self.assertFalse(fx["multi_old"].exists())
        self.assertFalse(fx["hist_old_dir"].exists())
        self.assertTrue(live_ws.is_dir())

        # 5. --rename-on-disk --apply
        rn_parent = self.root / "rename_e2e"
        rn_parent.mkdir()
        rn_old = rn_parent / "AppOne"
        rn_old.mkdir()
        rn_new = rn_parent / ("appone" if self.platform_mode == "macos" else "app-two")
        rn_ws = self.user_dir / "workspaceStorage" / ("c" * 32)
        rn_ws.mkdir(parents=True)
        (rn_ws / "workspace.json").write_text(json.dumps({"folder": posix_uri(str(rn_old))}), encoding="utf-8")
        rn_res = self.run_cli("--new-project-path", str(rn_new), "--old-folder-name", rn_old.name, "--rename-on-disk", "--apply")
        self.assertEqual(rn_res.returncode, 0, rn_res.stdout + rn_res.stderr)
        self.assertIn("VERIFIED", rn_res.stdout)
        self.assertTrue(rn_new.is_dir())
        actual_names = [p.name for p in rn_parent.iterdir()]
        self.assertEqual(actual_names, [rn_new.name])


@unittest.skipUnless(sys.platform == "linux", "Native Linux runner only")
class LinuxNativeTests(_NativePosixE2EMixin, unittest.TestCase):
    """Native end-to-end tests for migrate-antigravity-workspace-linux.sh."""

    script_path = LINUX_SCRIPT
    platform_mode = "linux"

    def test_linux_e2e(self) -> None:
        self.run_native_e2e_suite()


@unittest.skipUnless(sys.platform == "darwin", "Native macOS runner only")
class MacOSNativeTests(_NativePosixE2EMixin, unittest.TestCase):
    """Native end-to-end tests for migrate-antigravity-workspace-macos.sh."""

    script_path = MACOS_SCRIPT
    platform_mode = "macos"

    def test_macos_e2e(self) -> None:
        self.run_native_e2e_suite()


if __name__ == "__main__":
    unittest.main()
