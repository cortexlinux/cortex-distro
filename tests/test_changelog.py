import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import changelog  # noqa: E402

SAMPLE_CHANGELOG = textwrap.dedent(
    """
    docker (24.0.7-1) stable; urgency=medium

      * Security: CVE-2023-12345 fixed in container runtime.
      * Bug fixes: Container restart issues.
      * New: BuildKit 0.12 support.

     -- CX Maintainer <dev@example.com>  Wed, 15 Nov 2023 10:00:00 +0000

    docker (24.0.6-1) stable; urgency=low

      * Bug fixes: Improve image pull retries.

     -- CX Maintainer <dev@example.com>  Fri, 20 Oct 2023 10:00:00 +0000
    """
).strip()


class ChangelogViewerTests(unittest.TestCase):
    def test_parse_entries_and_security_detection(self):
        entries = changelog.parse_changelog(SAMPLE_CHANGELOG)

        self.assertEqual([entry.version for entry in entries], ["24.0.7-1", "24.0.6-1"])
        self.assertTrue(entries[0].has_security_fix)
        self.assertFalse(entries[1].has_security_fix)
        self.assertIn("Container restart issues", entries[0].changes[1])

    def test_parse_dash_bullets_and_extra_maintainer_spacing(self):
        text = textwrap.dedent(
            """
            curl (8.5.0-1) stable; urgency=medium

              - Fix HTTP retry handling.

             -- CX Maintainer <dev@example.com>    Mon, 01 Jan 2024 10:00:00 +0000
            """
        ).strip()

        entries = changelog.parse_changelog(text)

        self.assertEqual(entries[0].changes, ("Fix HTTP retry handling.",))
        self.assertEqual(entries[0].maintainer, "CX Maintainer <dev@example.com>")
        self.assertEqual(entries[0].date, "Mon, 01 Jan 2024 10:00:00 +0000")

    def test_search_and_compare_versions(self):
        entries = changelog.parse_changelog(SAMPLE_CHANGELOG)

        self.assertEqual([entry.version for entry in changelog.filter_entries(entries, "BuildKit")], ["24.0.7-1"])
        compared = changelog.compare_entries(entries, "24.0.6-1", "24.0.7-1")
        self.assertEqual([entry.version for entry in compared], ["24.0.7-1", "24.0.6-1"])

        with self.assertRaises(ValueError):
            changelog.compare_entries(entries, "24.0.5-1", "24.0.7-1")
        with self.assertRaises(ValueError):
            changelog.compare_entries(entries, "24.0.7-1", "24.0.6-1")

    def test_export_json_and_cli_output(self):
        with tempfile.TemporaryDirectory() as tempdir:
            temp = Path(tempdir)
            source = temp / "changelog"
            output = temp / "out.json"
            source.write_text(SAMPLE_CHANGELOG, encoding="utf-8")

            # Safe in this test: invoke the local helper with a fixed Python executable
            # and argument list, never a shell-interpreted command string.
            result = subprocess.run(  # noqa: S603
                [
                    sys.executable,
                    str(ROOT / "scripts" / "changelog.py"),
                    "--file",
                    str(source),
                    "--security",
                    "--export",
                    str(output),
                ],
                check=True,
                text=True,
                capture_output=True,
            )

            self.assertIn("CVE-2023-12345", result.stdout)
            exported = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(len(exported), 1)
            self.assertTrue(exported[0]["has_security_fix"])

    def test_export_creates_parent_directories(self):
        with tempfile.TemporaryDirectory() as tempdir:
            output = Path(tempdir) / "nested" / "out.json"

            changelog.export_entries(changelog.parse_changelog(SAMPLE_CHANGELOG), output)

            self.assertTrue(output.exists())

    def test_cli_rejects_missing_or_invalid_compare_bounds(self):
        with tempfile.TemporaryDirectory() as tempdir:
            source = Path(tempdir) / "changelog"
            source.write_text(SAMPLE_CHANGELOG, encoding="utf-8")

            # Safe in this test: invoke the local helper with a fixed Python executable
            # and argument list, never a shell-interpreted command string.
            result = subprocess.run(  # noqa: S603
                [
                    sys.executable,
                    str(ROOT / "scripts" / "changelog.py"),
                    "docker",
                    "24.0.5-1",
                    "24.0.7-1",
                    "--file",
                    str(source),
                ],
                check=False,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("compare bounds not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
