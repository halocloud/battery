#!/usr/bin/env python3
"""Installer validation and rollback fixtures; never invokes sudo or changes system files."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
ASSET = ROOT / "out/BatteryCore-0.1.0-macos-arm64.tar.gz"
FILES = ["batteryctl", "batteryd", "smc", "uninstall", "common.sh", "manifest.json",
         "verified-hardware.json", "SMC-LICENSE", "SMC-SOURCE.md", "README.md",
         "local.batterycore.daemon.plist", "preinstall", "postinstall"]


def function_call(name, *args):
    return subprocess.run(["/bin/bash", "-c", 'source "$1"; shift; "$@"', "fixture",
                           str(INSTALLER), name, *map(str, args)],
                          capture_output=True, text=True, timeout=20)


class RemoteInstallerTests(unittest.TestCase):
    def fixture(self, path, names=FILES, link=None):
        with tarfile.open(path, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
            for name in names:
                info = tarfile.TarInfo(name)
                data = b"fixture"
                if name == link:
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/tmp/outside"
                    archive.addfile(info)
                else:
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))

    def test_source_has_no_install_side_effects(self):
        result = subprocess.run(["/bin/bash", "-c", 'source "$1"; printf sourced', "fixture", str(INSTALLER)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "sourced")

    def test_privileged_stdin_script_is_valid_bash(self):
        result = subprocess.run(["/bin/bash", "-c", 'source "$1"; declare -f fail check_platform verify_hash validate_archive restore_previous_tools install_as_root',
                                 "fixture", str(INSTALLER)], capture_output=True, text=True, check=True)
        checked = subprocess.run(["/bin/bash", "-n"], input=result.stdout + '\ninstall_as_root "$1" "$2"\n',
                                 capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_rejects_bad_hash_before_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.tar.gz"
            archive.write_bytes(b"bad download")
            result = function_call("verify_hash", archive, "0" * 64)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)

    def test_rejects_malformed_hash_and_archive_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "archive"
            archive.write_bytes(b"fixture")
            result = function_call("verify_hash", archive, "not-a-hash")
            self.assertIn("Invalid SHA", result.stderr)
            link = Path(temporary) / "link"
            link.symlink_to(archive)
            result = function_call("verify_hash", link, hashlib.sha256(b"fixture").hexdigest())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("regular file", result.stderr)

    def test_rejects_traversal_absolute_extra_duplicate_and_missing_entries(self):
        variants = [FILES + ["../outside"], FILES + ["/tmp/outside"], FILES + ["extra"],
                    FILES[:-1] + [FILES[0]], FILES[:-1]]
        for names in variants:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as temporary:
                archive, extracted = Path(temporary) / "bad.tar.gz", Path(temporary) / "extracted"
                self.fixture(archive, names)
                result = function_call("validate_archive", archive, extracted)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(extracted.iterdir()), [])

    def test_rejects_symlink_and_hardlink_entries(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                archive, extracted = Path(temporary) / "bad.tar.gz", Path(temporary) / "extracted"
                with tarfile.open(archive, "w:gz", format=tarfile.USTAR_FORMAT) as tar:
                    for name in FILES:
                        info = tarfile.TarInfo(name)
                        if name == "smc":
                            info.type = kind; info.linkname = "batteryctl"
                        tar.addfile(info, io.BytesIO(b""))
                result = function_call("validate_archive", archive, extracted)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("links and special files", result.stderr)
                self.assertEqual(list(extracted.iterdir()), [])

    def test_check_only_validates_real_release_without_installing(self):
        if not ASSET.exists():
            self.skipTest("Build remote release first")
        if os.geteuid() == 0:
            self.skipTest("Bootstrap intentionally rejects root invocation")
        digest = hashlib.sha256(ASSET.read_bytes()).hexdigest()
        result = subprocess.run(["/bin/bash", str(INSTALLER), "--archive", str(ASSET),
                                 "--sha256", digest, "--check-only"], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no sudo, service installation, or SMC execution", result.stdout)
        with tarfile.open(ASSET) as archive:
            self.assertEqual(sorted(archive.getnames()), sorted(FILES))
            manifest = json.load(archive.extractfile("manifest.json"))
            self.assertEqual(manifest["smcSHA256"], hashlib.sha256(archive.extractfile("smc").read()).hexdigest())

    def test_bad_version_is_rejected_before_network_access(self):
        result = function_call("download_release", "../../bad", "/not-created")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Version must", result.stderr)

    def test_unprivileged_root_worker_stops_before_mutation(self):
        if os.geteuid() == 0:
            self.skipTest("Never run root worker as root in tests")
        result = function_call("install_as_root", "/not-used", "0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Administrator authorization", result.stderr)

    def test_rollback_preserves_old_tools_if_they_were_never_moved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, backup = Path(temporary) / "tools", Path(temporary) / "backup"
            root.mkdir(); backup.mkdir(); (root / "old").write_text("old")
            result = function_call("restore_previous_tools", root, backup, "1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "old").read_text(), "old")

    def test_rollback_restores_moved_tools_or_removes_failed_fresh_install(self):
        for fresh in (True, False):
            with self.subTest(fresh=fresh), tempfile.TemporaryDirectory() as temporary:
                root, backup = Path(temporary) / "tools", Path(temporary) / "backup"
                root.mkdir(); backup.mkdir(); (root / "new").write_text("new")
                if not fresh:
                    (backup / "tools").mkdir(); (backup / "tools/old").write_text("old")
                result = function_call("restore_previous_tools", root, backup, "0" if fresh else "1")
                self.assertEqual(result.returncode, 0, result.stderr)
                if fresh:
                    self.assertFalse(root.exists())
                else:
                    self.assertEqual((root / "old").read_text(), "old")
                    self.assertFalse((root / "new").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
