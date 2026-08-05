# DORA metrics self-diagnosing report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `dora-metrics` skill diagnose repository configuration and access problems while it measures, and explain the fix steps for each one inside the same report — in the chat reply and in the saved `.md`, with identical content.

**Architecture:** The script emits every problem as a structured `issue` with a stable `code`. `references/troubleshooting.md` stays the only place the remediation prose lives; a new parser module reads it by anchor and the script hydrates each issue with its steps before serializing. The saved `.md` therefore contains the steps, and the `report-writer` subagent stops doing text matching — it renders what the JSON already carries.

**Tech Stack:** Python 3 standard library + `requests` (already a dependency). Tests: `unittest`, no network (GitHub calls mocked at function level).

## Global Constraints

- All work happens inside `skills/dora-metrics/`. Paths in this plan are relative to that directory unless stated otherwise.
- No new third-party dependencies. Parsing is stdlib `re` only.
- The skill never interprets, ranks, scores or compares projects, repos or people. Every message and every piece of guidance is about **measurement setup only** — why a data point is missing and how to fix the setup. Never whether a number is good or bad.
- The script never invents guidance. A code with no entry in `troubleshooting.md` renders the raw message plus an explicit "no guidance" line.
- `r["warnings"]` must stay an array of the raw message strings. `tests/e2e/run_e2e.py:251` and `:292` assert on its contents (`any("v0.6.0" in w and "0 merged PRs" in w ...)`), and the three existing warning texts must remain byte-identical.
- Existing unit tests must keep passing except where a task explicitly updates them.
- Run tests from `skills/dora-metrics/`: `python3 -m unittest discover -s tests -p "test_*.py" -v`.
- Commit style: Conventional Commits. Commit on the current branch; do not create branches.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/troubleshooting.py` | **New.** Parse `references/troubleshooting.md` into `{code: {what, how_to_check, where_to_fix}}`. Knows nothing about DORA. |
| `scripts/dora_metrics.py` | Issue model (`ISSUE_CODES`, `make_issue`, `hydrate_issues`, `has_blocked`), pre-flight checks, marker diagnostics, renderer sections, exit codes. |
| `references/troubleshooting.md` | Single source of truth for the remediation prose, one anchored entry per code. |
| `agents/report-writer.md` | Renders `issues[].guidance` from the JSON. No lookup, no text matching. |
| `assets/report-template.md` | Example output showing the problems-and-steps section. |
| `SKILL.md` | Step 3 (auth no longer aborts) and Step 5 (report rules). |
| `README.md` | Output example with `issues`. |
| `tests/test_troubleshooting.py` | **New.** Parser tests + the drift test. |
| `tests/test_dora_metrics.py` | Diagnostics, renderer and exit-code tests. |

---

### Task 1: Guidance parser

**Files:**
- Create: `scripts/troubleshooting.py`
- Test: `tests/test_troubleshooting.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `load_guidance(path: str) -> dict[str, dict[str, str]]`. Keys are codes; each value has exactly the keys `what`, `how_to_check`, `where_to_fix` (values are stripped strings, `""` when the subsection is absent). Returns `{}` when the file does not exist.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_troubleshooting.py`:

```python
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


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -p "test_troubleshooting.py" -v`
Expected: FAIL — `FileNotFoundError` / import error, `scripts/troubleshooting.py` does not exist.

- [ ] **Step 3: Write the parser**

Create `scripts/troubleshooting.py`:

```python
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
        guidance[m.group(1)] = _parse_entry(text[m.end():end])
    return guidance


def default_path() -> str:
    """Path to the troubleshooting file that ships next to this module."""
    return os.path.join(os.path.dirname(__file__), "..", "references", "troubleshooting.md")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -p "test_troubleshooting.py" -v`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/troubleshooting.py skills/dora-metrics/tests/test_troubleshooting.py
git commit -m "feat(dora-metrics): parse troubleshooting guidance by code anchor"
```

---

### Task 2: Restructure `references/troubleshooting.md`

**Files:**
- Modify: `references/troubleshooting.md` (whole file)
- Test: `tests/test_troubleshooting.py` (add one class)

**Interfaces:**
- Consumes: `load_guidance` from Task 1.
- Produces: anchored entries for these 13 codes — `no_credential`, `repo_unreachable`, `token_unauthorized`, `rate_limited`, `branch_not_found`, `no_markers_at_all`, `no_markers_matching_pattern`, `deploy_source_mismatch`, `matching_releases_all_draft`, `no_markers_in_window`, `first_marker_no_prior`, `no_prs_in_range`, `pr_first_commit_unfetchable`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_troubleshooting.py`, before the `if __name__` block:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_troubleshooting.py" -v`
Expected: FAIL on `test_has_every_expected_code` — the current file has no anchors, so the parsed set is empty.

- [ ] **Step 3: Rewrite `references/troubleshooting.md`**

Keep the existing intro paragraph (the "measurement-setup aid, not a performance guide" framing) but replace the matching instructions, since codes replace text matching. Then write one anchored entry per code. The three existing entries keep their prose, reshaped from `**What.**` paragraphs into `### What` subsections; the auth entry becomes `no_credential`; the unanchored "Setup check: Deployment Frequency count looks incomplete" section stays at the end **without** an anchor (it is human-only context and the parser ignores it).

Full file:

````markdown
# Troubleshooting — problems and how to fix them

> This guide is a **measurement-setup** aid, not a performance guide. Every
> entry here diagnoses **why a specific data point is missing or unmeasurable**
> (a wrong branch, a missing token scope, a tagging gap) and how to fix the
> **setup** so the next run measures correctly. Nothing here says whether a
> number is good or bad, or what a team should do differently — interpreting the
> numbers is a separate, deliberately later step, outside this skill's scope
> (Goodhart's Law).

This file is **machine-read**. Each entry is preceded by an anchor comment
`<!-- code: some_code -->` matching a code the script emits, and holds three
subsections: `### What`, `### How to check`, `### Where to fix`. The script
parses them (`scripts/troubleshooting.py`) and embeds them in its JSON output
and in the saved Markdown report, so the steps travel with the report instead of
being looked up by hand. Editing the prose here changes what every future report
says — that is the point. Do not rename the subsection headings and do not
remove an anchor without also removing the code from `ISSUE_CODES` in
`scripts/dora_metrics.py`; a test asserts the two stay in sync.

Sections without an anchor are for human readers only and are ignored by the
parser.

---

<!-- code: no_credential -->
## No GitHub credential found

### What

Before any measurement, the script needs a GitHub credential and found neither a
`GITHUB_TOKEN` environment variable nor a logged-in `gh` CLI. Nothing could be
measured in this run — the report contains this problem and no numbers.

### How to check

Run `gh auth status` to see whether the GitHub CLI is logged in, and
`echo $GITHUB_TOKEN` to see whether the env var is set in the shell you run the
script from. Whichever credential you use must have **read** access to every org
that owns one of the project's repos (a multi-org project needs access to each
org).

### Where to fix

- Option 1: `export GITHUB_TOKEN=ghp_xxxx` with a token that has repo **read**
  scope for those orgs.
- Option 2: run `gh auth login` once (if the GitHub CLI is installed) — the
  script detects it automatically via `gh auth token`, nothing to export.

---

<!-- code: repo_unreachable -->
## The repo is unreachable with this credential

### What

`GET /repos/{owner}/{repo}` returned 404 or 403, so the script cannot read
anything about this repo and skipped it. The other repos of the project were
still measured. A 404 here does not necessarily mean the repo is gone: GitHub
returns 404 rather than 403 for private repos a credential cannot see.

### How to check

- Confirm the `repo` value in `config/projects.json` is the current
  `org/repo` — a renamed or transferred repo keeps redirecting in the browser
  but the configured path may no longer be the canonical one.
- Open the repo on GitHub with the same account that owns the credential. If you
  cannot see it there either, it is an access problem, not a config typo.
- For a multi-org project, check the credential covers **that** org. Access to
  one org says nothing about the other.

### Where to fix

- Wrong path: correct `repos[].repo` in `config/projects.json`.
- Missing access: re-issue the token with repo **read** scope for that org, or
  have the org grant the account access. For a fine-grained token, the org must
  also approve it.

---

<!-- code: token_unauthorized -->
## The credential was rejected (401)

### What

The GitHub API returned 401 Unauthorized. The credential exists but is not
valid — expired, revoked, or malformed. Nothing could be read for this repo.

### How to check

Run `gh auth status`, or `curl -sI -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user`
and check for `HTTP/2 200`. A 401 there confirms the token itself, independent of
any repo.

### Where to fix

Issue a new token and `export GITHUB_TOKEN=...`, or re-run `gh auth login`.
Classic tokens can expire silently; fine-grained tokens also expire and lose
access when their org approval is revoked.

---

<!-- code: rate_limited -->
## GitHub API rate limit reached

### What

GitHub returned 403 with a rate-limit message, so the run stopped reading data
for this repo. This is not a configuration problem — it is a quota one. The
Search API (used for merged PRs) has a much lower limit than the REST API.

### How to check

Run `gh api rate_limit` and look at the `search` and `core` blocks: `remaining`
and the `reset` timestamp.

### Where to fix

- Re-run after the reset time shown by `gh api rate_limit`.
- Run fewer projects per invocation with `--project`, instead of the whole
  config at once.
- Make sure a credential is actually being used — unauthenticated requests have
  drastically lower limits.

---

<!-- code: branch_not_found -->
## The configured production branch does not exist

### What

`GET /repos/{owner}/{repo}/branches/{prod_branch}` returned 404: the branch named
in `repos[].prod_branch` is not in the repo. Deployment Frequency is unaffected
(it counts deploy markers, which do not depend on the branch), but Lead Time
cannot be computed, because the PR population is defined as PRs merged into that
branch.

### How to check

Open the repo's branch list on GitHub, or run
`gh api repos/{owner}/{repo}/branches --jq '.[].name'`, and compare with the
`prod_branch` in `config/projects.json`. Common mismatches: `master` vs `main`,
or a repo that deploys from `production` / `release`.

### Where to fix

Correct `repos[].prod_branch` in `config/projects.json`. Confirm the change
before saving — the config is shared by the team. To test a branch without
touching the config, use `--branch <branch>` for a one-off run.

---

<!-- code: no_markers_at_all -->
## The repo has no deploy markers at all

### What

The repo has no marker of the configured kind: no published Releases when
`deploy_source` is `"release"`, or no tags when it is `"tag"`. With no marker
there is nothing to count as a deploy, so Deployment Frequency is 0 and Lead
Time has nothing to measure against — regardless of how much was actually
deployed.

### How to check

Open the repo's Releases and Tags pages on GitHub (or
`gh api repos/{owner}/{repo}/releases --jq '.[].tag_name'` and
`gh api repos/{owner}/{repo}/tags --jq '.[].name'`) and check which of the two,
if either, the repo actually uses.

### Where to fix

- The repo does use one of them but not the configured one: set
  `repos[].deploy_source` in `config/projects.json` accordingly (`"release"` or
  `"tag"`).
- The repo marks no deploys at all: this is an instrumentation gap. Lead Time
  and Deployment Frequency are defined against a deploy marker, so until each
  production deploy creates a Release or a tag, this repo cannot be measured.
  Adding that step to the release process is a setup choice for the repo.

---

<!-- code: no_markers_matching_pattern -->
## The repo has markers, but none match `tag_pattern`

### What

Releases or tags exist, but none of their names match the `tag_pattern` regex,
so none was counted as a deploy. The report lists the actual names found — this
is almost always a naming mismatch, not an absence of deploys.

### How to check

Compare the names in the report's evidence with the `tag_pattern` in
`config/projects.json` (global, or the repo's own override). The default
`^v\d+\.\d+\.\d+$` matches `v1.4.0` and nothing else — not `1.4.0` (no `v`),
not `v1.4` (two components), not `v1.4.0-rc1` or `v1.4.0+build.22` (suffixes),
not `release-2026-07-01`.

### Where to fix

Set `repos[].tag_pattern` in `config/projects.json` to a regex matching that
repo's real naming, leaving the global pattern for the repos that follow it. The
pattern is matched with `re.match`, so it is anchored at the start; anchor the
end with `$` if you want an exact match. Example for a build-number suffix:
`^v\d+\.\d+\.\d+\+\d+$`.

---

<!-- code: deploy_source_mismatch -->
## `deploy_source` points at the wrong kind of marker

### What

Nothing matched with the configured `deploy_source`, but markers matching
`tag_pattern` **do** exist of the other kind — the repo tags without publishing
Releases, or publishes Releases while `deploy_source` says `"tag"`. The script
looked in the right repo for the wrong thing.

### How to check

The report's evidence lists the matching names found on the other side. Confirm
on GitHub that those are what the team treats as a production deploy.

### Where to fix

Flip `repos[].deploy_source` in `config/projects.json` to the kind that exists
(`"release"` or `"tag"`) and re-run. To check before editing the shared config,
use the one-off `--deploy-source {release,tag}` flag.

---

<!-- code: matching_releases_all_draft -->
## The matching Releases are all drafts

### What

Releases whose tag matches `tag_pattern` exist, but every one of them is a
draft. A draft Release is not published, so the script does not count it as a
deploy — a draft means the deploy was not announced, and counting it would
inflate Deployment Frequency with deploys that may never have happened.

### How to check

Open the repo's Releases page: drafts are labelled **Draft** and are only
visible to users with write access. `gh api repos/{owner}/{repo}/releases --jq '.[] | select(.draft) | .tag_name'`
lists them.

### Where to fix

Publish the Releases that correspond to real deploys, or adjust the release
process so the final step publishes rather than saves a draft. If the team
deliberately keeps drafts and marks deploys with plain tags instead, set
`repos[].deploy_source` to `"tag"`.

---

<!-- code: no_markers_in_window -->
## No deploy markers inside the measurement window

### What

Deployment Frequency is 0 for a plain reason: the repo does have deploy markers
in its history, but none of them falls inside the measured window. The report
states how many exist and the date of the most recent one. This is a fact about
the window, not a setup problem.

### How to check

Nothing to check. If you expected a deploy inside the window and the marker for
it is missing, the relevant entries are `no_markers_matching_pattern` (the
marker exists under a different name) or the tag-discipline section at the end
of this file (the deploy happened but produced no marker).

### Where to fix

Nothing to fix. Use `--window-days N` for a one-off run over a longer window if
you want to see the surrounding history.

---

<!-- code: first_marker_no_prior -->
## The earliest deploy has no prior marker to bound against

### What

This deploy is the first one the script can see in the repo's history for the
configured marker (`deploy_source`: Release or plain tag). Lead Time is measured
against the *previous* deploy, so with no prior marker there is no lower bound
for the PR population — the script skips Lead Time for this deploy and says so.
The deploy still counts toward Deployment Frequency; only its Lead Time is
excluded.

### How to check

In the repo's GitHub Releases (or tags) page, confirm this is in fact the
earliest marker matching `tag_pattern`. If it is, this is structural and
expected.

### Where to fix

Nothing to fix — this is not a setup problem. It resolves on its own once a
second deploy exists to bound against. If instead you *expected* an earlier
deploy to exist and be recognized, that points at a different entry: an earlier
tag/release that does not match `tag_pattern` (check `config/projects.json` →
`tag_pattern`, global or the repo's override) would not be seen, which can make a
later deploy look like "the first".

---

<!-- code: no_prs_in_range -->
## No merged PRs found between two deploys

### What

Between this deploy and the previous one, the script found no PRs merged into
the configured production branch, so it has nothing from which to compute Lead
Time for this deploy. This is usually a **measurement-setup** mismatch rather
than a real absence of changes.

### How to check

- In `config/projects.json`, read the repo's `prod_branch` and compare it to the
  branch PRs actually merge into on GitHub. If PRs merge into `master`,
  `production`, `release`, etc. but `prod_branch` says `main` (or vice versa),
  the query looks at the wrong base and finds nothing.
- On GitHub, open the repo's merged PRs for the interval between the two deploy
  tags and check their **base** branch. If changes reached the branch via direct
  pushes or fast-forward merges **without a PR**, the Search API cannot see them
  (Lead Time is defined only over merged PRs — see
  `references/lead-time-for-changes.md`).

### Where to fix

- Wrong branch: correct `repos[].prod_branch` in `config/projects.json` (or use
  `--branch <branch>` for a one-off check without editing the config). Confirm
  the change before saving — the config is shared by the team.
- Changes landing without PRs: this is a process/instrumentation detail of the
  repo. Routing production changes through PRs is what makes Lead Time
  measurable; that is a setup choice for the repo, not something this guide ranks
  or scores.

---

<!-- code: pr_first_commit_unfetchable -->
## A PR's first commit could not be fetched

### What

The script found the merged PR but could not read its commit list from the
GitHub API, so it has no first-commit timestamp to start Lead Time from and
excludes that single PR. The other PRs in the interval are unaffected.

### How to check

- Confirm the token can read that repo's PR commits: open the PR on GitHub with
  the same account and check `pulls/N/commits` is visible. A token missing repo
  read scope (or org access, for a multi-org project) can return the PR from
  Search but fail on the commit fetch.
- Open the PR on GitHub and check its commit history is present and not empty
  (unusual merge history — e.g. a PR whose commits were rewritten or whose head
  was force-removed — can leave no fetchable commits).

### Where to fix

- Token scope/access: use a `GITHUB_TOKEN` (or `gh auth login` session) with
  **read** access to that repo and to **all** the orgs of the project's repos.
  See the `no_credential` entry above.
- Genuinely empty/unusual commit history: nothing to fix in config — this PR is
  correctly excluded because its first commit is unrecoverable.

---

## Setup check: Deployment Frequency count looks incomplete (tag/deploy discipline)

> No anchor: this section is for a human who suspects the number is incomplete,
> not a problem the script can detect on its own.

**What.** Deployment Frequency counts deploy markers (Releases or tags matching
`tag_pattern`) in the window. If a production deploy happened but was **not**
tagged/released per the repo's `deploy_source`, the script has no marker to count
and that deploy is not reflected in the number. This is a measurement/
instrumentation gap, not a statement about the number itself.

**How to check.** If you suspect the count does not reflect every deploy, verify
that **each** production deploy in the window actually produced a marker matching
the repo's configured `deploy_source`:

- `deploy_source: "release"` — a published (non-draft) GitHub Release whose tag
  matches `tag_pattern`.
- `deploy_source: "tag"` — a git tag whose name matches `tag_pattern`.

Cross-check the repo's Releases/tags list on GitHub against the deploys you know
happened.

**Where to fix.**

- Marker missing for a real deploy: add the missing Release/tag in the repo, or
  align the repo's release process so every prod deploy creates the configured
  marker.
- Marker present but not matching: see the `no_markers_matching_pattern` entry
  above.

This is purely a check on whether every deploy is *instrumented*. It does not
comment on how often the repo deploys or whether that cadence is adequate — that
would be interpreting performance, which is out of scope.
````

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_troubleshooting.py" -v`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/references/troubleshooting.md skills/dora-metrics/tests/test_troubleshooting.py
git commit -m "docs(dora-metrics): restructure troubleshooting into anchored, parseable entries"
```

---

### Task 3: Issue model in the script

**Files:**
- Modify: `scripts/dora_metrics.py` (add after `VALID_DEPLOY_SOURCES`, around line 219)
- Test: `tests/test_dora_metrics.py` (add one class)

**Interfaces:**
- Consumes: `load_guidance`, `default_path` from Task 1.
- Produces:
  - `ISSUE_CODES: tuple[str, ...]` — every code the script can emit.
  - `NO_GUIDANCE_CODES: tuple[str, ...]` — codes deliberately absent from `troubleshooting.md`.
  - `make_issue(code: str, impact: str, message: str, evidence: dict | None = None) -> dict` — returns `{"code", "impact", "message", "evidence", "guidance": None}`. Raises `ValueError` on an unknown code or impact.
  - `iter_issues(result: dict)` — yields every issue dict in the result, root-level and per-repo.
  - `hydrate_issues(result: dict, guidance: dict) -> None` — sets `issue["guidance"]` in place.
  - `has_blocked(result: dict) -> bool`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_dora_metrics.py`, before the `if __name__` block:

```python
class TestIssueModel(unittest.TestCase):
    def test_make_issue_shape(self):
        i = dora_metrics.make_issue("branch_not_found", "partial", "msg", evidence={"prod_branch": "main"})
        self.assertEqual(i["code"], "branch_not_found")
        self.assertEqual(i["impact"], "partial")
        self.assertEqual(i["message"], "msg")
        self.assertEqual(i["evidence"], {"prod_branch": "main"})
        self.assertIsNone(i["guidance"])  # hydrated later, never at construction

    def test_make_issue_rejects_unknown_code(self):
        with self.assertRaises(ValueError):
            dora_metrics.make_issue("not_a_real_code", "partial", "msg")

    def test_make_issue_rejects_unknown_impact(self):
        with self.assertRaises(ValueError):
            dora_metrics.make_issue("branch_not_found", "critical", "msg")

    def test_hydrate_fills_root_and_repo_issues(self):
        result = {
            "issues": [dora_metrics.make_issue("no_credential", "blocked", "m")],
            "projects": [{"name": "P", "repos": [
                {"repo": "a/b", "issues": [dora_metrics.make_issue("branch_not_found", "partial", "m")]},
            ]}],
        }
        guidance = {"no_credential": {"what": "w1", "how_to_check": "h1", "where_to_fix": "f1"},
                    "branch_not_found": {"what": "w2", "how_to_check": "h2", "where_to_fix": "f2"}}
        dora_metrics.hydrate_issues(result, guidance)
        self.assertEqual(result["issues"][0]["guidance"]["what"], "w1")
        self.assertEqual(result["projects"][0]["repos"][0]["issues"][0]["guidance"]["what"], "w2")

    def test_hydrate_leaves_guidance_none_when_code_absent(self):
        result = {"issues": [dora_metrics.make_issue("github_api_error", "blocked", "m")], "projects": []}
        dora_metrics.hydrate_issues(result, {})
        self.assertIsNone(result["issues"][0]["guidance"])

    def test_has_blocked(self):
        blocked = {"issues": [], "projects": [{"name": "P", "repos": [
            {"repo": "a/b", "issues": [dora_metrics.make_issue("repo_unreachable", "blocked", "m")]}]}]}
        partial = {"issues": [], "projects": [{"name": "P", "repos": [
            {"repo": "a/b", "issues": [dora_metrics.make_issue("branch_not_found", "partial", "m")]}]}]}
        self.assertTrue(dora_metrics.has_blocked(blocked))
        self.assertFalse(dora_metrics.has_blocked(partial))


class TestGuidanceDrift(unittest.TestCase):
    """Every code the script emits must have an entry in troubleshooting.md and
    vice versa. Without this the single source of truth drifts silently and
    reports start showing problems with no steps."""

    def test_codes_and_entries_match(self):
        import importlib.util as _ilu
        path = os.path.join(os.path.dirname(__file__), "..", "scripts", "troubleshooting.py")
        spec = _ilu.spec_from_file_location("troubleshooting", path)
        troubleshooting = _ilu.module_from_spec(spec)
        spec.loader.exec_module(troubleshooting)

        documented = set(troubleshooting.load_guidance(troubleshooting.default_path()))
        expected = set(dora_metrics.ISSUE_CODES) - set(dora_metrics.NO_GUIDANCE_CODES)
        self.assertEqual(documented, expected)
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — `module 'dora_metrics' has no attribute 'make_issue'`.

- [ ] **Step 3: Add the issue model**

In `scripts/dora_metrics.py`, add `import sys`-adjacent imports at the top (after `import sys`):

```python
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import troubleshooting  # noqa: E402  (sibling module, loaded by path so the script stays runnable from anywhere)
```

Then, right after the `VALID_DEPLOY_SOURCES` line:

```python
# --- Issue model -----------------------------------------------------------
# Every problem the script reports is an "issue" with a stable code. The code is
# what links it to its remediation steps in references/troubleshooting.md, so
# the steps travel inside the report instead of being matched by text at render
# time. "impact" describes whether the MEASUREMENT succeeded, never whether a
# number is good: blocked = nothing measurable at that level, partial = measured
# with a declared gap, none = a factual note with nothing to fix.
ISSUE_IMPACTS = ("blocked", "partial", "none")

ISSUE_CODES = (
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
    "github_api_error",
)

# Codes with no entry in troubleshooting.md, on purpose. github_api_error is a
# catch-all for unexpected API failures: there is no fixed remediation, so the
# report shows the raw message. Kept as an explicit list so the drift test can
# tell "deliberate exception" from "someone forgot to document a code".
NO_GUIDANCE_CODES = ("github_api_error",)


def make_issue(code: str, impact: str, message: str, evidence: dict = None) -> dict:
    """Builds one issue. `guidance` is filled in later by hydrate_issues, never
    here — the script must never carry remediation prose of its own."""
    if code not in ISSUE_CODES:
        raise ValueError(f"unknown issue code '{code}' (add it to ISSUE_CODES and to references/troubleshooting.md).")
    if impact not in ISSUE_IMPACTS:
        raise ValueError(f"unknown impact '{impact}' (valid: {', '.join(ISSUE_IMPACTS)}).")
    return {"code": code, "impact": impact, "message": message, "evidence": evidence or {}, "guidance": None}


def iter_issues(result: dict):
    """Yields every issue in the result: root-level ones (global problems, not
    tied to a repo) and each repo's."""
    for issue in result.get("issues", []):
        yield issue
    for project in result.get("projects", []):
        for repo in project.get("repos", []):
            for issue in repo.get("issues", []):
                yield issue


def hydrate_issues(result: dict, guidance: dict) -> None:
    """Attaches the What / How to check / Where to fix steps to each issue, in
    place. A code with no entry keeps guidance=None and the renderer says so
    explicitly — it never invents steps."""
    for issue in iter_issues(result):
        issue["guidance"] = guidance.get(issue["code"])


def has_blocked(result: dict) -> bool:
    return any(i["impact"] == "blocked" for i in iter_issues(result))
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS, all tests including the drift test.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "feat(dora-metrics): add coded issue model with guidance hydration"
```

---

### Task 4: `compute_repo_metrics` emits issues

**Files:**
- Modify: `scripts/dora_metrics.py:222-291` (`compute_repo_metrics`)
- Test: `tests/test_dora_metrics.py` (add to `TestComputeRepoMetrics`)

**Interfaces:**
- Consumes: `make_issue` from Task 3.
- Produces: `compute_repo_metrics` returns two new keys, `"issues"` (list of issue dicts) and `"markers_total"` / `"latest_marker_at"`; `"warnings"` becomes derived. The three warning message strings are unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `TestComputeRepoMetrics` in `tests/test_dora_metrics.py`:

```python
    def test_warnings_are_derived_from_issues_with_identical_text(self):
        releases = self._releases([("v1.0.0", "2026-07-01T00:00:00Z")])
        with patch.object(dora_metrics, "get_prod_releases", return_value=releases):
            r = dora_metrics.compute_repo_metrics(
                session=None, repo="a/b", branch="main", tag_pattern=r"^v",
                window_days=14, now=dt("2026-07-03T00:00:00Z"),
            )
        self.assertEqual([i["code"] for i in r["issues"]], ["first_marker_no_prior"])
        self.assertEqual(r["warnings"], [i["message"] for i in r["issues"]])

    def test_marker_totals_are_reported_for_later_diagnosis(self):
        releases = self._releases([
            ("v1.0.0", "2026-05-01T00:00:00Z"),   # outside the window
            ("v1.1.0", "2026-07-01T00:00:00Z"),
        ])
        with patch.object(dora_metrics, "get_prod_releases", return_value=releases), \
             patch.object(dora_metrics, "get_merged_prs_between", return_value=[]):
            r = dora_metrics.compute_repo_metrics(
                session=None, repo="a/b", branch="main", tag_pattern=r"^v",
                window_days=14, now=dt("2026-07-03T00:00:00Z"),
            )
        self.assertEqual(r["markers_total"], 2)
        self.assertEqual(r["latest_marker_at"], "2026-07-01T00:00:00Z")

    def test_no_markers_at_all_reports_zero_totals(self):
        with patch.object(dora_metrics, "get_prod_releases", return_value=[]):
            r = dora_metrics.compute_repo_metrics(
                session=None, repo="a/b", branch="main", tag_pattern=r"^v",
                window_days=14, now=dt("2026-07-03T00:00:00Z"),
            )
        self.assertEqual(r["markers_total"], 0)
        self.assertIsNone(r["latest_marker_at"])
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — `KeyError: 'issues'` and `KeyError: 'markers_total'`.

- [ ] **Step 3: Rewrite the warning paths as issues**

In `compute_repo_metrics`, replace `warnings = []` (line 225) with `issues = []`, and replace the three `warnings.append(...)` calls with:

```python
            issues.append(make_issue(
                "first_marker_no_prior", "partial",
                f"{marker_label} {dep['tag']} has no known prior {marker_label.lower()} — "
                "the PR population can't be bounded, it's excluded from the Lead Time.",
                evidence={"tag": dep["tag"], "deploy_source": deploy_source},
            ))
```

```python
            issues.append(make_issue(
                "no_prs_in_range", "partial",
                f"{marker_label} {dep['tag']}: 0 merged PRs found in the range — check the base branch/convention.",
                evidence={"tag": dep["tag"], "prev_tag": prev_dep["tag"], "prod_branch": branch},
            ))
```

```python
                issues.append(make_issue(
                    "pr_first_commit_unfetchable", "partial",
                    f"PR #{pr['number']}: could not fetch the first commit, it's excluded.",
                    evidence={"pr": pr["number"], "tag": dep["tag"]},
                ))
```

The message strings are byte-identical to today's — `tests/e2e/run_e2e.py` asserts on them.

Then replace the returned dict's `"warnings": warnings,` line with:

```python
        "markers_total": len(all_deploys),
        "latest_marker_at": fmt_ts(all_deploys[-1]["published_at"]) if all_deploys else None,
        "issues": issues,
        # Derived, kept for consumers that read the raw strings (the E2E suite
        # asserts on them). Issues with impact "none" are notes, not warnings.
        "warnings": [i["message"] for i in issues if i["impact"] != "none"],
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS — including the pre-existing `test_first_release_excluded_from_lead_time_with_warning`, `test_zero_prs_between_releases_warns` and `test_pr_without_recoverable_commit_is_excluded_with_warning`, which still assert on `r["warnings"]`.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "refactor(dora-metrics): emit runtime warnings as coded issues"
```

---

### Task 5: Pre-flight repo checks

**Files:**
- Modify: `scripts/dora_metrics.py` (new function after `get_merged_prs_between`, before `VALID_DEPLOY_SOURCES`)
- Test: `tests/test_dora_metrics.py` (add one class)

**Interfaces:**
- Consumes: `make_issue` from Task 3.
- Produces: `preflight_repo(session, repo: str, branch: str) -> list[dict]` — issues found before measuring. A `blocked` issue in the list means the repo must not be measured.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_dora_metrics.py`:

```python
class FakeResponse:
    def __init__(self, status_code, text=""):
        self.status_code = status_code
        self.text = text


class FakeSession:
    """Returns a canned response per URL suffix. Anything not listed 200s."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def get(self, url, params=None):
        self.calls.append(url)
        for suffix, resp in self.routes.items():
            if url.endswith(suffix):
                return resp
        return FakeResponse(200)


class TestPreflightRepo(unittest.TestCase):
    def test_all_good_returns_no_issues(self):
        session = FakeSession({})
        self.assertEqual(dora_metrics.preflight_repo(session, "a/b", "main"), [])

    def test_repo_404_is_blocked(self):
        session = FakeSession({"/repos/a/b": FakeResponse(404, "Not Found")})
        issues = dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertEqual([i["code"] for i in issues], ["repo_unreachable"])
        self.assertEqual(issues[0]["impact"], "blocked")

    def test_repo_401_is_token_unauthorized(self):
        session = FakeSession({"/repos/a/b": FakeResponse(401, "Bad credentials")})
        issues = dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertEqual([i["code"] for i in issues], ["token_unauthorized"])

    def test_rate_limit_is_its_own_code(self):
        session = FakeSession({"/repos/a/b": FakeResponse(403, "API rate limit exceeded for user")})
        issues = dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertEqual([i["code"] for i in issues], ["rate_limited"])

    def test_repo_403_without_rate_limit_is_unreachable(self):
        session = FakeSession({"/repos/a/b": FakeResponse(403, "Resource not accessible")})
        issues = dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertEqual([i["code"] for i in issues], ["repo_unreachable"])

    def test_branch_404_is_partial_and_names_the_branch(self):
        session = FakeSession({"/branches/master": FakeResponse(404, "Branch not found")})
        issues = dora_metrics.preflight_repo(session, "a/b", "master")
        self.assertEqual([i["code"] for i in issues], ["branch_not_found"])
        self.assertEqual(issues[0]["impact"], "partial")
        self.assertEqual(issues[0]["evidence"]["prod_branch"], "master")
        self.assertIn("master", issues[0]["message"])

    def test_branch_is_not_checked_when_the_repo_is_unreachable(self):
        session = FakeSession({"/repos/a/b": FakeResponse(404, "Not Found")})
        dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertTrue(all("/branches/" not in url for url in session.calls))

    def test_unexpected_status_is_github_api_error(self):
        session = FakeSession({"/repos/a/b": FakeResponse(500, "boom")})
        issues = dora_metrics.preflight_repo(session, "a/b", "main")
        self.assertEqual([i["code"] for i in issues], ["github_api_error"])
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — `module 'dora_metrics' has no attribute 'preflight_repo'`.

- [ ] **Step 3: Implement**

Add to `scripts/dora_metrics.py`:

```python
def _is_rate_limited(resp) -> bool:
    return resp.status_code == 403 and "rate limit" in (resp.text or "").lower()


def preflight_repo(session: requests.Session, repo: str, branch: str) -> list:
    """Checks, before measuring, the two things whose absence would otherwise
    produce a silent or misleading result: that the credential can see the repo
    at all, and that the configured production branch exists. Two cheap REST
    calls per repo (not Search, which is the rate-limited API).

    A returned issue with impact "blocked" means the repo cannot be measured;
    the caller skips it and keeps going with the rest of the project."""
    issues = []

    resp = session.get(f"{API_ROOT}/repos/{repo}")
    if resp.status_code == 401:
        return [make_issue("token_unauthorized", "blocked",
                           f"{repo}: 401 Unauthorized from the GitHub API — the credential is not valid for this repo.")]
    if _is_rate_limited(resp):
        return [make_issue("rate_limited", "blocked",
                           f"{repo}: GitHub API rate limit reached — it could not be measured in this run.")]
    if resp.status_code in (403, 404):
        return [make_issue("repo_unreachable", "blocked",
                           f"{repo}: the GitHub API returned {resp.status_code} — the repo is unreachable with this "
                           "credential, it could not be measured.",
                           evidence={"status": resp.status_code})]
    if resp.status_code != 200:
        return [make_issue("github_api_error", "blocked",
                           f"{repo}: GitHub API error {resp.status_code} on /repos/{repo}: {(resp.text or '')[:300]}",
                           evidence={"status": resp.status_code})]

    branch_resp = session.get(f"{API_ROOT}/repos/{repo}/branches/{branch}")
    if branch_resp.status_code == 404:
        issues.append(make_issue(
            "branch_not_found", "partial",
            f"{repo}: branch '{branch}' does not exist — Lead Time can't be measured against it "
            "(Deployment Frequency is unaffected).",
            evidence={"prod_branch": branch},
        ))
    return issues
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "feat(dora-metrics): pre-flight repo access and branch checks"
```

---

### Task 6: Marker diagnostics

**Files:**
- Modify: `scripts/dora_metrics.py` (new functions after `preflight_repo`)
- Test: `tests/test_dora_metrics.py` (add one class)

**Interfaces:**
- Consumes: `make_issue` (Task 3), `markers_total` / `latest_marker_at` from the repo result (Task 4).
- Produces:
  - `get_release_tag_names(session, repo) -> dict` with keys `"published"` and `"draft"`, each a list of tag-name strings.
  - `get_all_tag_names(session, repo) -> list[str]`.
  - `diagnose_markers(session, repo, tag_pattern, deploy_source, markers_total, deployment_frequency, latest_marker_at) -> list[dict]`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_dora_metrics.py`:

```python
class TestDiagnoseMarkers(unittest.TestCase):
    """diagnose_markers only touches the network when something needs
    explaining, so the happy path is asserted to make zero calls."""

    def _diagnose(self, **kw):
        params = dict(session=None, repo="a/b", tag_pattern=r"^v\d+\.\d+\.\d+$",
                      deploy_source="release", markers_total=0,
                      deployment_frequency=0, latest_marker_at=None)
        params.update(kw)
        return dora_metrics.diagnose_markers(**params)

    def test_healthy_repo_produces_no_issues_and_no_calls(self):
        with patch.object(dora_metrics, "get_release_tag_names") as names, \
             patch.object(dora_metrics, "get_all_tag_names") as tags:
            issues = self._diagnose(markers_total=3, deployment_frequency=2,
                                    latest_marker_at="2026-07-01T00:00:00Z")
        self.assertEqual(issues, [])
        names.assert_not_called()
        tags.assert_not_called()

    def test_no_markers_at_all(self):
        with patch.object(dora_metrics, "get_release_tag_names", return_value={"published": [], "draft": []}), \
             patch.object(dora_metrics, "get_all_tag_names", return_value=[]):
            issues = self._diagnose()
        self.assertEqual([i["code"] for i in issues], ["no_markers_at_all"])
        self.assertEqual(issues[0]["impact"], "partial")

    def test_markers_exist_but_none_match_the_pattern(self):
        found = ["release-2026-07-01", "release-2026-07-14"]
        with patch.object(dora_metrics, "get_release_tag_names", return_value={"published": found, "draft": []}), \
             patch.object(dora_metrics, "get_all_tag_names", return_value=found):
            issues = self._diagnose()
        self.assertEqual([i["code"] for i in issues], ["no_markers_matching_pattern"])
        self.assertEqual(issues[0]["evidence"]["names_found"], found)
        self.assertEqual(issues[0]["evidence"]["tag_pattern"], r"^v\d+\.\d+\.\d+$")

    def test_evidence_is_capped_at_five_names(self):
        found = [f"release-{n}" for n in range(12)]
        with patch.object(dora_metrics, "get_release_tag_names", return_value={"published": found, "draft": []}), \
             patch.object(dora_metrics, "get_all_tag_names", return_value=[]):
            issues = self._diagnose()
        self.assertEqual(len(issues[0]["evidence"]["names_found"]), 5)
        self.assertEqual(issues[0]["evidence"]["names_total"], 12)

    def test_deploy_source_mismatch_release_configured_but_tags_used(self):
        with patch.object(dora_metrics, "get_release_tag_names", return_value={"published": [], "draft": []}), \
             patch.object(dora_metrics, "get_all_tag_names", return_value=["v1.4.0", "v1.5.0"]):
            issues = self._diagnose()
        codes = [i["code"] for i in issues]
        self.assertIn("deploy_source_mismatch", codes)
        self.assertEqual(issues[codes.index("deploy_source_mismatch")]["evidence"]["matching_other_source"],
                         ["v1.4.0", "v1.5.0"])

    def test_deploy_source_mismatch_tag_configured_but_releases_used(self):
        with patch.object(dora_metrics, "get_all_tag_names", return_value=[]), \
             patch.object(dora_metrics, "get_release_tag_names", return_value={"published": ["v1.4.0"], "draft": []}):
            issues = self._diagnose(deploy_source="tag")
        self.assertIn("deploy_source_mismatch", [i["code"] for i in issues])

    def test_matching_releases_all_draft(self):
        with patch.object(dora_metrics, "get_release_tag_names",
                          return_value={"published": [], "draft": ["v1.4.0"]}), \
             patch.object(dora_metrics, "get_all_tag_names", return_value=[]):
            issues = self._diagnose()
        codes = [i["code"] for i in issues]
        self.assertIn("matching_releases_all_draft", codes)

    def test_drafts_are_not_checked_for_deploy_source_tag(self):
        with patch.object(dora_metrics, "get_all_tag_names", return_value=[]), \
             patch.object(dora_metrics, "get_release_tag_names", return_value={"published": [], "draft": ["v1.4.0"]}):
            issues = self._diagnose(deploy_source="tag")
        self.assertNotIn("matching_releases_all_draft", [i["code"] for i in issues])

    def test_markers_exist_but_none_in_window_is_impact_none(self):
        issues = self._diagnose(markers_total=4, deployment_frequency=0,
                                latest_marker_at="2026-05-02T00:00:00Z")
        self.assertEqual([i["code"] for i in issues], ["no_markers_in_window"])
        self.assertEqual(issues[0]["impact"], "none")
        self.assertIn("2026-05-02T00:00:00Z", issues[0]["message"])
        self.assertIn("4", issues[0]["message"])
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — `module 'dora_metrics' has no attribute 'diagnose_markers'`.

- [ ] **Step 3: Implement**

Add to `scripts/dora_metrics.py`, after `preflight_repo`:

```python
EVIDENCE_SAMPLE_SIZE = 5


def get_release_tag_names(session: requests.Session, repo: str) -> dict:
    """Tag names of every Release in the repo, split by draft state. Used only
    to explain an empty result — the measurement itself goes through
    get_prod_releases."""
    published, draft = [], []
    for r in gh_paginate(session, f"{API_ROOT}/repos/{repo}/releases"):
        name = r.get("tag_name", "")
        if not name:
            continue
        (draft if r.get("draft") else published).append(name)
    return {"published": published, "draft": draft}


def get_all_tag_names(session: requests.Session, repo: str) -> list:
    """Every git tag name in the repo, unfiltered."""
    return [t.get("name", "") for t in gh_paginate(session, f"{API_ROOT}/repos/{repo}/tags") if t.get("name")]


def diagnose_markers(session: requests.Session, repo: str, tag_pattern: str, deploy_source: str,
                     markers_total: int, deployment_frequency: int, latest_marker_at: str) -> list:
    """Explains a deploy count of 0 instead of leaving it mute — the difference
    between 'they didn't deploy' and 'the repo isn't instrumented' is invisible
    in the number alone, and only the second one is fixable.

    Costs nothing when markers were found inside the window: the extra API calls
    run only on the paths that need evidence."""
    if markers_total > 0:
        if deployment_frequency == 0:
            return [make_issue(
                "no_markers_in_window", "none",
                f"{repo}: 0 deploys in the window. {markers_total} deploy marker(s) exist in history, "
                f"the most recent on {latest_marker_at}.",
                evidence={"markers_total": markers_total, "latest_marker_at": latest_marker_at},
            )]
        return []

    issues = []
    pattern = re.compile(tag_pattern)
    releases = get_release_tag_names(session, repo)
    tag_names = get_all_tag_names(session, repo)

    if deploy_source == "tag":
        own_names, own_label = tag_names, "tags"
        other_names, other_label = releases["published"], "published Releases"
    else:
        own_names, own_label = releases["published"], "published Releases"
        other_names, other_label = tag_names, "tags"

    if not own_names:
        issues.append(make_issue(
            "no_markers_at_all", "partial",
            f"{repo}: no {own_label} at all — there is no deploy marker to count.",
            evidence={"deploy_source": deploy_source},
        ))
    else:
        issues.append(make_issue(
            "no_markers_matching_pattern", "partial",
            f"{repo}: {len(own_names)} {own_label} found, none matching tag_pattern "
            f"'{tag_pattern}' — no deploy marker was counted.",
            evidence={"tag_pattern": tag_pattern,
                      "names_found": own_names[:EVIDENCE_SAMPLE_SIZE],
                      "names_total": len(own_names)},
        ))

    if deploy_source == "release":
        matching_drafts = [n for n in releases["draft"] if pattern.match(n)]
        if matching_drafts:
            issues.append(make_issue(
                "matching_releases_all_draft", "partial",
                f"{repo}: {len(matching_drafts)} Release(s) matching tag_pattern exist but are all drafts — "
                "drafts are not counted as deploys.",
                evidence={"draft_tags": matching_drafts[:EVIDENCE_SAMPLE_SIZE]},
            ))

    matching_other = [n for n in other_names if pattern.match(n)]
    if matching_other:
        issues.append(make_issue(
            "deploy_source_mismatch", "partial",
            f"{repo}: deploy_source is '{deploy_source}' and nothing matched, but {len(matching_other)} "
            f"{other_label} matching tag_pattern do exist.",
            evidence={"deploy_source": deploy_source,
                      "matching_other_source": matching_other[:EVIDENCE_SAMPLE_SIZE]},
        ))
    return issues
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "feat(dora-metrics): diagnose why a repo produced no deploy markers"
```

---

### Task 7: Render problems and steps in the report

**Files:**
- Modify: `scripts/dora_metrics.py:294-324` (`format_human_summary`)
- Test: `tests/test_dora_metrics.py` (`TestFormatHumanSummary`)

**Interfaces:**
- Consumes: hydrated issues from Task 3.
- Produces: `format_human_summary(result, window_days)` renders, per repo, a `**Problems found and how to fix them:**` block for `blocked`/`partial` issues and a `**Notes:**` block for `impact: none`, each issue followed by its What / How to check / Where to fix. Root-level issues render under a `# DORA Metrics` heading at the top. Unmeasured repos (`measured: False`) render without metric lines.

- [ ] **Step 1: Write the failing tests**

Replace the whole `TestFormatHumanSummary` class in `tests/test_dora_metrics.py` with:

```python
class TestFormatHumanSummary(unittest.TestCase):
    GUIDANCE = {"what": "The branch is missing.",
                "how_to_check": "Compare with the repo's branch list.",
                "where_to_fix": "Correct prod_branch in config/projects.json."}

    def _repo(self, **kw):
        base = {"repo": "example-org/example-frontend", "type": ["web", "mobile"],
                "deploy_source": "release", "measured": True, "deployment_frequency": 2,
                "lead_time_median_hours": 4.3, "lead_time_n": 3, "issues": [], "warnings": []}
        base.update(kw)
        return base

    def _result(self, repos, root_issues=None):
        return {"issues": root_issues or [], "projects": [{"name": "Example Project", "repos": repos}]}

    def test_includes_metrics(self):
        text = dora_metrics.format_human_summary(self._result([self._repo()]), window_days=14)
        self.assertIn("# DORA Metrics — Example Project", text)
        self.assertIn("## `example-org/example-frontend` (web, mobile) — deploy_source: release", text)
        self.assertIn("**Deployment Frequency** (window 14d): 2", text)
        self.assertIn("**Median Lead Time**: 4.3h (n=3)", text)
        self.assertNotIn("**Problems found", text)

    def test_no_lead_time_data(self):
        text = dora_metrics.format_human_summary(
            self._result([self._repo(deployment_frequency=0, lead_time_median_hours=None, lead_time_n=0)]),
            window_days=14)
        self.assertIn("no data in the window", text)

    def test_problem_renders_message_verbatim_then_the_steps(self):
        issue = dora_metrics.make_issue("branch_not_found", "partial", "a/b: branch 'master' does not exist")
        issue["guidance"] = self.GUIDANCE
        text = dora_metrics.format_human_summary(
            self._result([self._repo(issues=[issue], warnings=[issue["message"]])]), window_days=14)
        self.assertIn("**Problems found and how to fix them:**", text)
        self.assertIn("a/b: branch 'master' does not exist", text)
        self.assertIn("**What:** The branch is missing.", text)
        self.assertIn("**How to check:** Compare with the repo's branch list.", text)
        self.assertIn("**Where to fix:** Correct prod_branch in config/projects.json.", text)

    def test_issue_without_guidance_says_so_instead_of_inventing(self):
        issue = dora_metrics.make_issue("github_api_error", "blocked", "a/b: GitHub API error 500")
        text = dora_metrics.format_human_summary(
            self._result([self._repo(measured=False, issues=[issue])]), window_days=14)
        self.assertIn("a/b: GitHub API error 500", text)
        self.assertIn("no guidance for 'github_api_error'", text)
        self.assertNotIn("**What:**", text)

    def test_impact_none_renders_under_notes_not_problems(self):
        issue = dora_metrics.make_issue("no_markers_in_window", "none", "a/b: 0 deploys in the window.")
        issue["guidance"] = {"what": "Nothing wrong.", "how_to_check": "", "where_to_fix": "Nothing to fix."}
        text = dora_metrics.format_human_summary(
            self._result([self._repo(deployment_frequency=0, issues=[issue])]), window_days=14)
        self.assertIn("**Notes:**", text)
        self.assertNotIn("**Problems found and how to fix them:**", text)
        self.assertNotIn("**How to check:**", text)  # empty subsection is skipped, not rendered blank

    def test_unmeasured_repo_shows_the_problem_and_no_metric_lines(self):
        issue = dora_metrics.make_issue("repo_unreachable", "blocked", "a/b: the GitHub API returned 404")
        issue["guidance"] = self.GUIDANCE
        text = dora_metrics.format_human_summary(
            self._result([{"repo": "a/b", "type": [], "deploy_source": "release",
                           "measured": False, "issues": [issue], "warnings": [issue["message"]]}]),
            window_days=14)
        self.assertIn("## `a/b` — not measured", text)
        self.assertNotIn("**Deployment Frequency**", text)
        self.assertIn("a/b: the GitHub API returned 404", text)

    def test_root_issue_renders_at_the_top(self):
        issue = dora_metrics.make_issue("no_credential", "blocked", "No GitHub credential found.")
        issue["guidance"] = self.GUIDANCE
        text = dora_metrics.format_human_summary({"issues": [issue], "projects": []}, window_days=14)
        self.assertTrue(text.startswith("# DORA Metrics"))
        self.assertIn("No GitHub credential found.", text)
        self.assertIn("**Problems found and how to fix them:**", text)
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — the current renderer emits `**Warnings:**` and knows nothing about `issues`, `measured` or root-level issues.

- [ ] **Step 3: Rewrite the renderer**

Replace `format_human_summary` (and add the two helpers above it) in `scripts/dora_metrics.py`:

```python
GUIDANCE_LABELS = (("what", "What"), ("how_to_check", "How to check"), ("where_to_fix", "Where to fix"))


def _render_issue(issue: dict, lines: list) -> None:
    """One issue: the raw message first, exactly as produced, then its steps.
    The message is never rewritten — an issue with no guidance says so out loud
    rather than getting invented steps."""
    lines.append(f"- {issue['message']}")
    guidance = issue.get("guidance")
    if not guidance:
        lines.append(f"  - _(no guidance for '{issue['code']}' in references/troubleshooting.md)_")
        return
    for key, label in GUIDANCE_LABELS:
        text = (guidance.get(key) or "").strip()
        if not text:
            continue
        body = " ".join(text.split())
        lines.append(f"  - **{label}:** {body}")


def _render_issue_groups(issues: list, lines: list) -> None:
    """Problems (blocked/partial) and notes (impact none) are separated on
    purpose: a note explains a number, it is not something to fix."""
    problems = [i for i in issues if i["impact"] != "none"]
    notes = [i for i in issues if i["impact"] == "none"]
    if problems:
        lines.append("**Problems found and how to fix them:**")
        lines.append("")
        for issue in problems:
            _render_issue(issue, lines)
        lines.append("")
    if notes:
        lines.append("**Notes:**")
        lines.append("")
        for issue in notes:
            _render_issue(issue, lines)
        lines.append("")


def format_human_summary(result: dict, window_days: int) -> str:
    """Renders the fetched data as a readable Markdown report — the same
    numbers printed to stdout, plus, for every problem found, the steps to fix
    it. Pure formatting: no interpretation, no ranking, no number and no
    guidance that isn't already in the result."""
    lines = []

    root_issues = result.get("issues", [])
    if root_issues:
        lines.append("# DORA Metrics")
        lines.append("")
        _render_issue_groups(root_issues, lines)

    for p in result["projects"]:
        lines.append(f"# DORA Metrics — {p['name']}")
        lines.append("")
        for r in p["repos"]:
            type_label = ", ".join(r.get("type", [])) or "unspecified"
            if not r.get("measured", True):
                lines.append(f"## `{r['repo']}` — not measured")
                lines.append("")
                _render_issue_groups(r.get("issues", []), lines)
                continue
            lines.append(f"## `{r['repo']}` ({type_label}) — deploy_source: {r.get('deploy_source', 'release')}")
            lines.append("")
            lines.append(f"- **Deployment Frequency** (window {window_days}d): {r['deployment_frequency']}")
            if r["lead_time_median_hours"] is not None:
                lines.append(f"- **Median Lead Time**: {r['lead_time_median_hours']}h (n={r['lead_time_n']})")
            else:
                lines.append("- **Median Lead Time**: no data in the window")
            lines.append("")
            _render_issue_groups(r.get("issues", []), lines)
    return "\n".join(lines).rstrip() + "\n"
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS. The old `test_repo_error_is_rendered` no longer exists — it was replaced by `test_unmeasured_repo_shows_the_problem_and_no_metric_lines`.

- [ ] **Step 5: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "feat(dora-metrics): render fix steps next to every problem in the report"
```

---

### Task 8: Wire it into `main()`

**Files:**
- Modify: `scripts/dora_metrics.py:360-457` (`main`)
- Test: `tests/test_dora_metrics.py` (add one class)

**Interfaces:**
- Consumes: `preflight_repo` (Task 5), `diagnose_markers` (Task 6), `hydrate_issues` / `has_blocked` (Task 3), `troubleshooting.load_guidance` (Task 1).
- Produces: `build_result(session, projects, tag_pattern, window_days, now) -> dict` — the measured result with issues attached but not yet hydrated. `main()` handles credentials, hydration, output and exit code.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_dora_metrics.py`:

```python
class TestBuildResult(unittest.TestCase):
    PROJECTS = [{"name": "P", "repos": [{"repo": "a/b", "type": ["web"], "prod_branch": "main"}]}]

    def test_blocked_repo_is_not_measured(self):
        blocked = [dora_metrics.make_issue("repo_unreachable", "blocked", "unreachable")]
        with patch.object(dora_metrics, "preflight_repo", return_value=blocked), \
             patch.object(dora_metrics, "compute_repo_metrics") as compute:
            result = dora_metrics.build_result(
                session=None, projects=self.PROJECTS, tag_pattern=r"^v", window_days=14,
                now=dt("2026-07-03T00:00:00Z"))
        compute.assert_not_called()
        repo = result["projects"][0]["repos"][0]
        self.assertFalse(repo["measured"])
        self.assertEqual([i["code"] for i in repo["issues"]], ["repo_unreachable"])

    def test_preflight_and_marker_issues_are_merged_in_order(self):
        preflight = [dora_metrics.make_issue("branch_not_found", "partial", "branch")]
        metrics = {"repo": "a/b", "deployment_frequency": 0, "lead_time_median_hours": None,
                   "lead_time_n": 0, "markers_total": 0, "latest_marker_at": None,
                   "issues": [], "warnings": []}
        markers = [dora_metrics.make_issue("no_markers_at_all", "partial", "no markers")]
        with patch.object(dora_metrics, "preflight_repo", return_value=preflight), \
             patch.object(dora_metrics, "compute_repo_metrics", return_value=dict(metrics)), \
             patch.object(dora_metrics, "diagnose_markers", return_value=markers):
            result = dora_metrics.build_result(
                session=None, projects=self.PROJECTS, tag_pattern=r"^v", window_days=14,
                now=dt("2026-07-03T00:00:00Z"))
        repo = result["projects"][0]["repos"][0]
        self.assertEqual([i["code"] for i in repo["issues"]], ["branch_not_found", "no_markers_at_all"])
        self.assertEqual(repo["warnings"], [i["message"] for i in repo["issues"]])
        self.assertTrue(repo["measured"])

    def test_api_exception_mid_measurement_becomes_a_coded_issue(self):
        with patch.object(dora_metrics, "preflight_repo", return_value=[]), \
             patch.object(dora_metrics, "compute_repo_metrics",
                          side_effect=dora_metrics.GitHubError("401 Unauthorized. Check that GITHUB_TOKEN...")):
            result = dora_metrics.build_result(
                session=None, projects=self.PROJECTS, tag_pattern=r"^v", window_days=14,
                now=dt("2026-07-03T00:00:00Z"))
        repo = result["projects"][0]["repos"][0]
        self.assertFalse(repo["measured"])
        self.assertEqual([i["code"] for i in repo["issues"]], ["token_unauthorized"])

    def test_unrecognized_api_exception_falls_back_to_github_api_error(self):
        with patch.object(dora_metrics, "preflight_repo", return_value=[]), \
             patch.object(dora_metrics, "compute_repo_metrics",
                          side_effect=dora_metrics.GitHubError("GitHub API error 500 at ...")):
            result = dora_metrics.build_result(
                session=None, projects=self.PROJECTS, tag_pattern=r"^v", window_days=14,
                now=dt("2026-07-03T00:00:00Z"))
        self.assertEqual([i["code"] for i in result["projects"][0]["repos"][0]["issues"]], ["github_api_error"])

    def test_one_blocked_repo_does_not_stop_the_next(self):
        projects = [{"name": "P", "repos": [{"repo": "a/b", "prod_branch": "main"},
                                             {"repo": "a/c", "prod_branch": "main"}]}]
        metrics = {"repo": "a/c", "deployment_frequency": 1, "lead_time_median_hours": None,
                   "lead_time_n": 0, "markers_total": 1, "latest_marker_at": "2026-07-01T00:00:00Z",
                   "issues": [], "warnings": []}
        blocked = [dora_metrics.make_issue("repo_unreachable", "blocked", "unreachable")]
        with patch.object(dora_metrics, "preflight_repo", side_effect=[blocked, []]), \
             patch.object(dora_metrics, "compute_repo_metrics", return_value=dict(metrics)), \
             patch.object(dora_metrics, "diagnose_markers", return_value=[]):
            result = dora_metrics.build_result(
                session=None, projects=projects, tag_pattern=r"^v", window_days=14,
                now=dt("2026-07-03T00:00:00Z"))
        repos = result["projects"][0]["repos"]
        self.assertFalse(repos[0]["measured"])
        self.assertTrue(repos[1]["measured"])


class TestNoCredentialResult(unittest.TestCase):
    def test_builds_a_report_instead_of_dying(self):
        result = dora_metrics.no_credential_result(now=dt("2026-07-03T00:00:00Z"), window_days=14, tag_pattern=r"^v")
        self.assertEqual([i["code"] for i in result["issues"]], ["no_credential"])
        self.assertEqual(result["projects"], [])
        self.assertTrue(dora_metrics.has_blocked(result))
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest discover -s tests -p "test_dora_metrics.py" -v`
Expected: FAIL — `module 'dora_metrics' has no attribute 'build_result'`.

- [ ] **Step 3: Implement**

Add before `main()` in `scripts/dora_metrics.py`:

```python
def classify_github_error(repo: str, message: str) -> dict:
    """Maps an exception raised mid-measurement onto a code, so an access
    problem reaches the report with steps instead of as raw text."""
    lowered = message.lower()
    if "401" in message:
        return make_issue("token_unauthorized", "blocked",
                          f"{repo}: 401 Unauthorized from the GitHub API — the credential is not valid for this repo.")
    if "rate limit" in lowered:
        return make_issue("rate_limited", "blocked",
                          f"{repo}: GitHub API rate limit reached — it could not be measured in this run.")
    if "404" in message:
        return make_issue("repo_unreachable", "blocked",
                          f"{repo}: the GitHub API returned 404 — the repo is unreachable with this credential, "
                          "it could not be measured.",
                          evidence={"status": 404})
    return make_issue("github_api_error", "blocked", f"{repo}: {message}")


def build_result(session, projects, tag_pattern: str, window_days: int, now: datetime) -> dict:
    """Measures every repo of every project. A repo that can't be measured
    contributes its problems to the report and the run continues with the next
    one — a broken access on one repo must not cost the numbers of the others."""
    result = {
        "generated_at": fmt_ts(now),
        "window_days": window_days,
        "tag_pattern": tag_pattern,
        "issues": [],       # global problems, not tied to a repo
        "projects": [],
    }

    for project in projects:
        repos_result = []
        for repo_cfg in project["repos"]:
            repo = repo_cfg["repo"]
            branch = repo_cfg["prod_branch"]
            repo_tag_pattern = repo_cfg.get("tag_pattern", tag_pattern)
            deploy_source = repo_cfg.get("deploy_source", "release")

            issues = preflight_repo(session, repo, branch)
            if any(i["impact"] == "blocked" for i in issues):
                repos_result.append({
                    "repo": repo, "prod_branch": branch, "deploy_source": deploy_source,
                    "type": repo_cfg.get("type", []), "measured": False,
                    "issues": issues, "warnings": [i["message"] for i in issues],
                })
                continue

            try:
                r = compute_repo_metrics(session, repo, branch, repo_tag_pattern, window_days, now,
                                          deploy_source=deploy_source)
                r["issues"] = issues + r["issues"] + diagnose_markers(
                    session, repo, repo_tag_pattern, deploy_source,
                    r["markers_total"], r["deployment_frequency"], r["latest_marker_at"],
                )
                r["warnings"] = [i["message"] for i in r["issues"] if i["impact"] != "none"]
                r["measured"] = True
                r["type"] = repo_cfg.get("type", [])
            except (GitHubError, requests.exceptions.RequestException) as e:
                issues = issues + [classify_github_error(repo, str(e))]
                r = {
                    "repo": repo, "prod_branch": branch, "deploy_source": deploy_source,
                    "type": repo_cfg.get("type", []), "measured": False,
                    "issues": issues, "warnings": [i["message"] for i in issues],
                }
            repos_result.append(r)
        result["projects"].append({"name": project["name"], "repos": repos_result})
    return result


def no_credential_result(now: datetime, window_days: int, tag_pattern: str) -> dict:
    """The run can't measure anything, but it still produces a report: the
    person who ran it ends up with a file stating what happened and how to fix
    it, instead of a stderr line that scrolls away."""
    return {
        "generated_at": fmt_ts(now),
        "window_days": window_days,
        "tag_pattern": tag_pattern,
        "issues": [make_issue("no_credential", "blocked",
                              "No GitHub credential found — nothing could be measured in this run.")],
        "projects": [],
    }


def write_output(result: dict, window_days: int, out_dir: str, now: datetime) -> None:
    output_json = json.dumps(result, indent=2, ensure_ascii=False)
    summary = format_human_summary(result, window_days)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        base = os.path.join(out_dir, f"{now.strftime('%Y-%m-%d')}_dora")
        with open(f"{base}.json", "w") as f:
            f.write(output_json)
        with open(f"{base}.md", "w") as f:
            f.write(summary)
        print(f"Output saved to {base}.json and {base}.md\n")
    print(summary)
    print(output_json)
```

Then replace the body of `main()` from the `token = get_github_token()` line (line 378) to the end with:

```python
    guidance = troubleshooting.load_guidance(troubleshooting.default_path())
    now = datetime.now(timezone.utc)

    with open(args.config, "r") as f:
        config = json.load(f)

    tag_pattern = config["tag_pattern"]
    window_days = args.window_days if args.window_days is not None else config["window_days"]

    token = get_github_token()
    if not token:
        # No hard exit: the report itself carries the problem and its steps.
        result = no_credential_result(now, window_days, tag_pattern)
        hydrate_issues(result, guidance)
        write_output(result, window_days, args.out_dir, now)
        sys.exit(1)

    projects = config["projects"]
    if args.project:
        projects = [p for p in projects if p["name"].lower() == args.project.lower()]
        if not projects:
            print(f"ERROR: project '{args.project}' is not in {args.config}.", file=sys.stderr)
            sys.exit(1)
        if args.branch:
            for repo_cfg in projects[0]["repos"]:
                repo_cfg["prod_branch"] = args.branch
        if args.deploy_source:
            for repo_cfg in projects[0]["repos"]:
                repo_cfg["deploy_source"] = args.deploy_source

    try:
        validate_deploy_sources(projects)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    result = build_result(gh_session(token), projects, tag_pattern, window_days, now)
    hydrate_issues(result, guidance)
    write_output(result, window_days, args.out_dir, now)

    # Non-zero when something couldn't be measured at all, so CI notices. A
    # "partial" issue doesn't change it: the run measured, with declared gaps.
    sys.exit(1 if has_blocked(result) else 0)
```

- [ ] **Step 4: Run to verify it passes**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS.

- [ ] **Step 5: Smoke-test the no-credential path by hand**

Run: `env -u GITHUB_TOKEN PATH=/usr/bin:/bin python3 scripts/dora_metrics.py --out-dir /tmp/dora-smoke; echo "exit=$?"`
Expected: a Markdown report on stdout starting with `# DORA Metrics` containing "No GitHub credential found", the What / How to check / Where to fix steps, `Output saved to /tmp/dora-smoke/...`, and `exit=1`. (`PATH` is trimmed so `gh` is not found and the no-credential path is actually exercised.)

- [ ] **Step 6: Commit**

```bash
git add skills/dora-metrics/scripts/dora_metrics.py skills/dora-metrics/tests/test_dora_metrics.py
git commit -m "feat(dora-metrics): report access problems instead of aborting the run"
```

---

### Task 9: Update the skill docs

**Files:**
- Modify: `agents/report-writer.md`, `assets/report-template.md`, `SKILL.md`, `README.md`

**Interfaces:**
- Consumes: the JSON shape produced by Tasks 3-8.
- Produces: no code. This is what makes the agent render the steps instead of inventing them.

- [ ] **Step 1: Rewrite the `report-writer` rules**

In `agents/report-writer.md`:

Add `issues` to the "Relevant fields per repo" list (replacing the `warnings` bullet):

```markdown
- `measured` — false when the repo could not be measured at all; in that case
  there are no metric fields, only `issues`.
- `issues` — every problem found, each with `code`, `impact`
  (`blocked` / `partial` / `none`), `message`, `evidence` and `guidance`
  (`what`, `how_to_check`, `where_to_fix`, already filled in by the script).
- `warnings` — the same messages as plain strings, derived from `issues`. Kept
  for compatibility; render from `issues`.

The result also has a root-level `issues` list for problems that are not tied to
a repo (no credential, for example). Render those first.
```

Replace item 4 of "What to produce" with:

```markdown
4. For each repo with issues, a **"Problems found and how to fix them"** list
   covering the `blocked` and `partial` ones, and a separate **"Notes"** list
   for `impact: none`. Each entry: the `message` **verbatim**, then its
   `guidance` as What / How to check / Where to fix. Skip a subsection when it
   is empty. When `guidance` is null, show the message and say there is no
   guidance for that code — do not write steps of your own.
```

Replace the third bullet of "Rules" with:

```markdown
- **Render `issues[].guidance` exactly as the JSON provides it.** Do not look
  anything up, do not match warning text against `references/troubleshooting.md`,
  and never write remediation steps that are not in the JSON. The script already
  did the lookup; your job is to lay it out. If an issue has `guidance: null`,
  say so instead of filling the gap.
```

Keep the `tools: ["Read"]` frontmatter — the agent still reads the saved JSON when given a path. In the second `<example>` block of the frontmatter `description`, replace the assistant line so it no longer promises a lookup:

```
assistant: "I will show the problem verbatim under that repo, followed by the What / How to check / Where to fix steps the script already attached to it, and note that these are process-gap signals this calibration stage is meant to expose. I will not label it a problem of the team, assign severity, or suggest what to do about the numbers."
```

- [ ] **Step 2: Update the report template**

In `assets/report-template.md`, replace the "Warnings" block and its trailing note with:

````markdown
**Problems found and how to fix them** (`example-org/example-frontend`):

- `example-org/example-frontend: 3 published Releases found, none matching tag_pattern '^v\d+\.\d+\.\d+$' — no deploy marker was counted.`
  - **What:** Releases or tags exist, but none of their names match the
    `tag_pattern` regex, so none was counted as a deploy.
  - **How to check:** Compare the names in the evidence
    (`release-2026-07-01`, `release-2026-07-14`) with the `tag_pattern` in
    `config/projects.json`.
  - **Where to fix:** Set `repos[].tag_pattern` for that repo to a regex
    matching its real naming.

**Notes** (`example-partner-org/example-backend`):

- `example-partner-org/example-backend: 0 deploys in the window. 4 deploy marker(s) exist in history, the most recent on 2026-06-02T10:00:00Z.`
  - **What:** This is a fact about the window, not a setup problem.
  - **Where to fix:** Nothing to fix.

> Problems and notes come straight from the script's `issues`, message verbatim
> with the steps the script already attached from `references/troubleshooting.md`.
> Never add steps that are not in the JSON.
````

Update the structure notes in the HTML comment accordingly: replace the two bullets about warnings and troubleshooting lookup with:

```
- Add a "Problems found and how to fix them" sub-list under a repo when it has
  issues with impact blocked/partial, and a "Notes" sub-list for impact none.
  Copy each `message` verbatim and render its `guidance` beneath it. Do NOT look
  anything up — the guidance is already in the JSON. If `guidance` is null, say
  there is none.
- Root-level `issues` (no credential, etc.) render before any project section.
- A repo with `measured: false` has no metric fields: render its problems only.
```

- [ ] **Step 3: Update `SKILL.md`**

Replace the last paragraph of "Step 3 — Verify authentication" with:

```markdown
If neither is available, the script no longer stops without output: it produces
the report anyway, containing the `no_credential` problem and the steps to fix
it (and saves it, if `--out-dir` was passed), and exits with code 1. Report it
like any other problem — do not ask the user to paste a token in the chat if the
flow is Cowork; in local Claude Code, suggest `gh auth login` if they haven't
done it.
```

Replace the fourth bullet of "Step 5 — Report" (the one starting "If there were `warnings`") with:

```markdown
- The script diagnoses the repo's setup while it measures: whether the
  credential can see the repo, whether `prod_branch` exists, whether there are
  deploy markers and whether they match `tag_pattern` or the configured
  `deploy_source`. Every problem found comes back in `issues` with its
  remediation steps already attached, read from `references/troubleshooting.md`.
  The `report-writer` renders each `message` **verbatim** with its steps
  beneath — problems (impact `blocked`/`partial`) and notes (impact `none`)
  under separate headings. It never looks anything up and never writes steps of
  its own: an issue with `guidance: null` is reported as having no guidance.
  These are process-gap signals this calibration stage is meant to expose, not
  noise to hide, and the steps stay strictly on the measurement-setup side —
  they never comment on whether a number is good or bad.
- A repo the script could not measure at all comes back with `measured: false`
  and no metric fields. Report it as such, with its problems — never omit the
  repo or substitute a zero.
```

Add to "Known limitations (pilot)":

```markdown
- The setup diagnosis costs 2 extra REST calls per repo (`/repos` and
  `/branches/{branch}`), plus 2 more only when a repo produced no deploy marker
  and the script needs evidence to explain why. These are REST, not the Search
  API that carries the low rate limit.
```

- [ ] **Step 4: Update `README.md`**

In the "Output example" section, extend the Markdown sample with a problems block and replace the JSON sample's `"warnings": []` line with:

```json
  "measured": true,
  "warnings": [],
  "issues": [
    {
      "code": "no_markers_in_window",
      "impact": "none",
      "message": "example-org/example-frontend: 0 deploys in the window. 4 deploy marker(s) exist in history, the most recent on 2026-06-02T10:00:00Z.",
      "evidence": {"markers_total": 4, "latest_marker_at": "2026-06-02T10:00:00Z"},
      "guidance": {"what": "...", "how_to_check": "...", "where_to_fix": "..."}
    }
  ]
```

Add a section after "Output example":

````markdown
## When it can't measure

The script diagnoses the repo's setup while it measures and reports every
problem it finds **inside the same report**, with the steps to fix it: an
unreachable repo or an invalid credential, a `prod_branch` that doesn't exist, a
repo with no deploy markers, markers that don't match `tag_pattern`, a
`deploy_source` pointing at the wrong kind of marker, matching Releases left as
drafts. Running with no credential at all still produces a report — the one
listing that problem — instead of dying on stderr.

The steps live in `references/troubleshooting.md`, one anchored entry per
problem code. That file is the single source of truth: the script parses it
(`scripts/troubleshooting.py`) and embeds the steps in the JSON and in the saved
`.md`, so editing the prose there changes every future report. Adding a new code
means adding it to `ISSUE_CODES` in `scripts/dora_metrics.py` **and** writing its
entry; a unit test fails if the two drift apart.

Exit code: 1 when something could not be measured at all (`impact: blocked`), 0
otherwise. A partially measured repo does not fail the run — the gaps are
declared in the report.
````

Also update the "Unit tests" paragraph to mention the new coverage:

```markdown
They mock `requests.Session` and run in seconds. They cover the DF/LT
calculation, the median, the exclusion of the first deploy, the setup
diagnostics and their remediation steps, the report rendering, and the
config/CLI validations. Run these whenever `scripts/dora_metrics.py` or
`references/troubleshooting.md` is touched.
```

- [ ] **Step 5: Verify the whole suite and the docs are consistent**

Run: `python3 -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS, everything.

Run: `grep -rn "troubleshooting.md" SKILL.md agents/report-writer.md assets/report-template.md`
Expected: no remaining instruction telling the `report-writer` to read or match against `troubleshooting.md`. The only mentions left describe where the prose lives.

- [ ] **Step 6: Commit**

```bash
git add skills/dora-metrics/SKILL.md skills/dora-metrics/README.md skills/dora-metrics/agents/report-writer.md skills/dora-metrics/assets/report-template.md
git commit -m "docs(dora-metrics): render diagnosed problems and steps from the JSON"
```

---

## Post-implementation check (not a task)

The E2E suite is not part of the plan's tasks — it needs a throwaway GitHub repo and network. Whoever has one should run it once before considering the work done:

```bash
python3 tests/e2e/run_e2e.py --repo your-user/some-throwaway-repo
```

It asserts on `r["warnings"]` at `run_e2e.py:251` and `:292`; those assertions must still pass, since Task 4 keeps the three warning strings byte-identical and keeps `warnings` derived from `issues`.
