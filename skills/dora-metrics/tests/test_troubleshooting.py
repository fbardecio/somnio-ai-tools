"""Unit tests for scripts/troubleshooting.py — the guidance parser.

No network, no fixtures on disk beyond a temp file written by the test itself.

Usage:
    python3 -m unittest discover -s tests -p "test_*.py" -v
"""

import importlib.util
import os
import tempfile
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts", "troubleshooting.py")
_spec = importlib.util.spec_from_file_location("troubleshooting", SCRIPT_PATH)
troubleshooting = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(troubleshooting)

SAMPLE = """# Troubleshooting

Intro prose that belongs to no code.

<!-- code: branch_not_found -->
## The configured prod_branch does not exist

### What

The branch is not in the repo.

### How to check

Open the repo's branch list.

### Where to fix

Correct `repos[].prod_branch` in `config/projects.json`.

---

<!-- code: rate_limited -->
## Rate limit reached

### What

Too many calls.

### Where to fix

Wait and re-run.

---

## A section with no anchor

This one is for humans only and must be ignored by the parser.
"""


class TestLoadGuidance(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".md")
        with os.fdopen(fd, "w") as f:
            f.write(SAMPLE)
        self.guidance = troubleshooting.load_guidance(self.path)

    def tearDown(self):
        os.unlink(self.path)

    def test_finds_every_anchored_code(self):
        self.assertEqual(set(self.guidance), {"branch_not_found", "rate_limited"})

    def test_parses_the_three_subsections(self):
        entry = self.guidance["branch_not_found"]
        self.assertEqual(entry["what"], "The branch is not in the repo.")
        self.assertEqual(entry["how_to_check"], "Open the repo's branch list.")
        self.assertEqual(entry["where_to_fix"], "Correct `repos[].prod_branch` in `config/projects.json`.")

    def test_missing_subsection_is_empty_string_not_absent(self):
        entry = self.guidance["rate_limited"]
        self.assertEqual(entry["how_to_check"], "")
        self.assertEqual(set(entry), {"what", "how_to_check", "where_to_fix"})

    def test_stops_at_the_horizontal_rule_and_ignores_unanchored_sections(self):
        self.assertNotIn("for humans only", self.guidance["rate_limited"]["where_to_fix"])

    def test_missing_file_returns_empty_dict(self):
        self.assertEqual(troubleshooting.load_guidance("/nonexistent/troubleshooting.md"), {})


EXPECTED_CODES = {
    "no_credential",
    "repo_unreachable",
    "token_unauthorized",
    "rate_limited",
    "branch_not_found",
    "no_markers_at_all",
    "no_markers_matching_pattern",
    "deploy_source_mismatch",
    "matching_releases_all_draft",
    "no_markers_in_window",
    "first_marker_no_prior",
    "no_prs_in_range",
    "pr_first_commit_unfetchable",
}


class TestRealTroubleshootingFile(unittest.TestCase):
    """The shipped file must actually parse — a broken anchor or a renamed
    subsection would silently strip the steps from every report."""

    def setUp(self):
        self.guidance = troubleshooting.load_guidance(troubleshooting.default_path())

    def test_has_every_expected_code(self):
        self.assertEqual(set(self.guidance), EXPECTED_CODES)

    def test_every_entry_has_what_and_where_to_fix(self):
        for code, entry in self.guidance.items():
            with self.subTest(code=code):
                self.assertTrue(entry["what"], f"{code} has no What")
                self.assertTrue(entry["where_to_fix"], f"{code} has no Where to fix")


if __name__ == "__main__":
    unittest.main()
