#!/usr/bin/env python3
"""Read-only packaging checks plus isolated fixture tests; never installs or invokes smc."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def test_absolute_system_commands_exist(self):
        paths = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "packaging/scripts").iterdir()) + [ROOT / "packaging/uninstall", ROOT / "install.sh"]
        for path in paths:
            for command in re.findall(r"(?<![\w/])/(?:usr/(?:bin|sbin)|bin|sbin)/[a-zA-Z0-9_-]+", path.read_text()):
                self.assertTrue(Path(command).is_file(), f"{path.name}: {command}")

    def test_shell_syntax(self):
        paths = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "packaging/scripts").iterdir()) + [ROOT / "packaging/uninstall", ROOT / "install.sh"]
        for path in paths:
            subprocess.run(["/bin/bash", "-n", str(path)], check=True, capture_output=True)

    def test_launchd_owns_foreground_service(self):
        with (ROOT / "packaging/local.batterycore.daemon.plist").open("rb") as handle:
            value = plistlib.load(handle)
        self.assertEqual(value["ProgramArguments"], ["/Library/PrivilegedHelperTools/local.batterycore/batteryd"])
        self.assertTrue(value["KeepAlive"])
        self.assertTrue(value["MachServices"][value["Label"]])
        self.assertGreaterEqual(value["ExitTimeOut"], 25)

    def test_no_fabricated_hardware_approvals(self):
        self.assertEqual(json.loads((ROOT / "packaging/verified-hardware.json").read_text()), [])

    def test_original_smc_digest(self):
        self.assertEqual(hashlib.sha256((ROOT.parent / "dist/smc").read_bytes()).hexdigest(),
                         "e3b4392c966dee700f3e1d6cc3812c0d487954c3d6d77b91f521a9590aadae44")

    def test_legacy_detection_in_isolated_fixtures(self):
        def detected(root):
            command = 'source "$1"; if legacy_files_present "$2"; then exit 11; fi; exit 0'
            result = subprocess.run(["/bin/bash", "-c", command, "fixture", str(ROOT / "packaging/scripts/common.sh"), str(root)])
            return result.returncode == 11
        with tempfile.TemporaryDirectory(prefix="batterycore-package-") as temporary:
            volume = Path(temporary)
            self.assertFalse(detected(volume))
            agent = volume / "Users/test/Library/LaunchAgents/com.battery.app.plist"
            agent.parent.mkdir(parents=True)
            agent.write_text("old agent")
            self.assertTrue(detected(volume))
            agent.unlink()
            self.assertFalse(detected(volume))
            sudoers = volume / "private/etc/sudoers.d/battery"
            sudoers.parent.mkdir(parents=True)
            sudoers.symlink_to("/nonexistent-target")
            self.assertTrue(detected(volume))

    def test_installer_rejects_unprivileged_execution(self):
        if os.geteuid() == 0:
            self.skipTest("Never execute installer scripts as root during tests")
        for name in ("preinstall", "postinstall"):
            result = subprocess.run(["/bin/bash", str(ROOT / "packaging/scripts" / name)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Administrator", result.stderr)

    def test_staged_package_when_available(self):
        stage = ROOT / "out/stage/root"
        if not stage.exists():
            self.skipTest("Build package to validate staging and signatures")
        tools = stage / "Library/PrivilegedHelperTools/local.batterycore"
        manifest = json.loads((tools / "manifest.json").read_text())
        self.assertEqual(hashlib.sha256((tools / "smc").read_bytes()).hexdigest(), manifest["smcSHA256"])
        for name in ("batteryctl", "batteryd", "smc"):
            executable = tools / name
            self.assertEqual(executable.stat().st_mode & 0o777, 0o755)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(executable)], check=True, capture_output=True)
        self.assertEqual(json.loads((tools / "verified-hardware.json").read_text()), [])
        self.assertTrue((tools / "SMC-LICENSE").is_file())
        self.assertTrue((tools / "SMC-SOURCE.md").is_file())
        for path in stage.rglob("*"):
            self.assertEqual(path.stat().st_mode & 0o022, 0, str(path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
