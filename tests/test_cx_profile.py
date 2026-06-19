import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "src" / "cx_profile.py"


class ProfileCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_profile(self, *args, state_dir=None):
        state_dir = state_dir or self.tmp_path
        env = os.environ.copy()
        env["CX_PROFILE_STATE"] = str(state_dir / "profiles.json")
        return subprocess.run(
            [sys.executable, str(CLI), *args],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_create_active_edit_and_history(self):
        result = self.run_profile("create", "development", "--package", "python3", "--package", "nodejs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("created", result.stdout)

        active = self.run_profile("active")
        self.assertEqual(active.returncode, 0)
        self.assertIn("Current: development", active.stdout)
        self.assertIn("nodejs", active.stdout)
        self.assertIn("python3", active.stdout)

        edited = self.run_profile("edit", "development", "--add", "docker.io", "--remove", "nodejs")
        self.assertEqual(edited.returncode, 0)

        history = self.run_profile("history", "development")
        self.assertEqual(history.returncode, 0)
        self.assertIn("create", history.stdout)
        self.assertIn("edit", history.stdout)

        data = json.loads((self.tmp_path / "profiles.json").read_text())
        self.assertEqual(data["active"], "development")
        self.assertEqual(data["profiles"]["development"]["packages"], ["docker.io", "python3"])
        self.assertEqual(len(data["profiles"]["development"]["versions"]), 2)

    def test_copy_switch_diff_and_validate(self):
        self.assertEqual(self.run_profile("create", "development", "-p", "nodejs", "-p", "python3").returncode, 0)
        self.assertEqual(self.run_profile("copy", "development", "production").returncode, 0)
        self.assertEqual(self.run_profile("edit", "production", "--remove", "nodejs", "--add", "nginx").returncode, 0)

        diff = self.run_profile("diff", "development", "production")
        self.assertEqual(diff.returncode, 0)
        self.assertIn("- nodejs", diff.stdout)
        self.assertIn("+ nginx", diff.stdout)

        switched = self.run_profile("switch", "production")
        self.assertEqual(switched.returncode, 0)
        self.assertIn("Switched to 'production'", switched.stdout)
        self.assertIn("- nodejs", switched.stdout)
        self.assertIn("+ nginx", switched.stdout)

        valid = self.run_profile("validate", "production")
        self.assertEqual(valid.returncode, 0)
        self.assertIn("is valid", valid.stdout)

    def test_export_import_profile(self):
        self.assertEqual(self.run_profile("create", "development", "-p", "python3").returncode, 0)
        export_path = self.tmp_path / "development.cx-profile.json"

        exported = self.run_profile("export", "development", str(export_path))
        self.assertEqual(exported.returncode, 0)
        payload = json.loads(export_path.read_text())
        self.assertEqual(payload["format"], "cx-profile")
        self.assertEqual(payload["profile"]["packages"], ["python3"])

        isolated = self.tmp_path / "imported"
        isolated.mkdir()
        imported = self.run_profile("import", str(export_path), "--name", "imported-dev", state_dir=isolated)
        self.assertEqual(imported.returncode, 0, imported.stderr)
        data = json.loads((isolated / "profiles.json").read_text())
        self.assertEqual(data["profiles"]["imported-dev"]["packages"], ["python3"])

    def test_validation_rejects_bad_profile_and_package_names(self):
        bad_profile = self.run_profile("create", "bad/name")
        self.assertEqual(bad_profile.returncode, 2)
        self.assertIn("Profile names", bad_profile.stderr)

        bad_package = self.run_profile("create", "development", "-p", "../bad")
        self.assertEqual(bad_package.returncode, 2)
        self.assertIn("Invalid package name", bad_package.stderr)


if __name__ == "__main__":
    unittest.main()
