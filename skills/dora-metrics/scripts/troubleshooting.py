#!/usr/bin/env python3
"""Parser for references/troubleshooting.md.

That markdown file is the single source of truth for the remediation steps
shown next to every problem the DORA script reports. This module turns it into
data so the script can embed the steps in its JSON and in the saved .md report,
instead of an agent looking them up by matching text at render time.

Contract of the file: each machine-readable entry is preceded by an anchor
comment `<!-- code: some_code -->` and contains up to three subsections,
`### What`, `### How to check` and `### Where to fix`. Sections without an
anchor are for human readers only and are ignored here.
"""

import os
import re

ANCHOR_RE = re.compile(r"^<!--\s*code:\s*([a-z0-9_]+)\s*-->\s*$", re.MULTILINE)
SUBSECTION_RE = re.compile(r"^###\s+(.+?)\s*$", re.MULTILINE)

# Heading text -> key in the returned entry. Any other ### heading is ignored.
_HEADING_TO_KEY = {
    "what": "what",
    "how to check": "how_to_check",
    "where to fix": "where_to_fix",
}
_KEYS = ("what", "how_to_check", "where_to_fix")


def _parse_entry(body: str) -> dict:
    """Splits one entry's body into its ### subsections. Missing subsections
    come back as empty strings so callers never have to guess whether a key
    exists — only whether it has content."""
    entry = {k: "" for k in _KEYS}
    matches = list(SUBSECTION_RE.finditer(body))
    for i, m in enumerate(matches):
        key = _HEADING_TO_KEY.get(m.group(1).strip().lower())
        if not key:
            continue
        end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        entry[key] = body[m.end():end].strip()
    return entry


def load_guidance(path: str) -> dict:
    """Reads the troubleshooting file and returns {code: {what, how_to_check,
    where_to_fix}}. A missing file returns {} — the caller degrades to showing
    the raw message, it never invents guidance."""
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        text = f.read()

    guidance = {}
    anchors = list(ANCHOR_RE.finditer(text))
    for i, m in enumerate(anchors):
        end = anchors[i + 1].start() if i + 1 < len(anchors) else len(text)

        # Stop at the first --- (horizontal rule) before the next anchor
        entry_text = text[m.end():end]
        hr_match = re.search(r'^---\s*$', entry_text, re.MULTILINE)
        if hr_match:
            end = m.end() + hr_match.start()

        guidance[m.group(1)] = _parse_entry(text[m.end():end])
    return guidance


def default_path() -> str:
    """Path to the troubleshooting file that ships next to this module."""
    return os.path.join(os.path.dirname(__file__), "..", "references", "troubleshooting.md")
