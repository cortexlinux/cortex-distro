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

    def test_search_and_compare_versions(self):
        entries = changelog.parse_changelog(SAMPLE_CHANGELOG)

        self.assertEqual([entry.version for entry in changelog.filter_entries(entries, "BuildKit")], ["24.0.7-1"])
        compared = changelog.compare_entries(entries, "24.0.6-1", "24.0.7-1")
        self.assertEqual([entry.version for entry in compared], ["24.0.7-1", "24.0.6-1"])

    def test_export_json_and_cli_output(self):
        with tempfile.TemporaryDirectory() as tempdir:
            temp = Path(tempdir)
            source = temp / "changelog"
            output = temp / "out.json"
            source.write_text(SAMPLE_CHANGELOG, encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "changelog.py"),
                    "docker",
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


if __name__ == "__main__":
    unittest.main()
