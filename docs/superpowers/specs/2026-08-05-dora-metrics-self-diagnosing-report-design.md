# DORA metrics — self-diagnosing report

**Date:** 2026-08-05
**Skill:** `skills/dora-metrics/`
**Status:** approved design, pending implementation plan

## Problem

The skill measures Deployment Frequency and Lead Time, but when it *can't*
measure — because a repo is misconfigured or the token lacks access — the
report does not say how to fix it. Today:

- Runtime warnings get What / How to check / Where to fix guidance, but only in
  the chat reply, inserted by the `report-writer` subagent via text matching
  against `references/troubleshooting.md`.
- The saved `.md` (`scripts/dora_metrics.py`, `format_human_summary`) dumps
  warnings verbatim with no guidance. The file someone shares with the team is
  the one without the steps.
- Per-repo API failures land as `{"repo": ..., "error": "<raw text>"}`. The
  `report-writer` has no instruction covering that field, so an access problem
  — exactly the case in scope — reaches the reader with no remediation.
- No GitHub credential aborts the run (`sys.exit(1)`) before any report exists,
  so the steps only ever appear on stderr.
- A repo whose `tag_pattern`, `deploy_source` or `prod_branch` is wrong reports
  `0 deploys` with no warning at all. Nothing distinguishes "didn't deploy"
  from "isn't instrumented".

## Goal

One run produces one report that contains both the numbers it could measure and
the concrete steps to fix every configuration or access problem it found — in
the chat reply and in the saved `.md`, with identical content.

Out of scope, unchanged: the skill never interprets, ranks, scores or compares
projects, repos or people. All guidance is strictly about measurement setup —
why a data point is missing and how to fix the setup — never about whether a
number is good or bad (Goodhart's Law).

## Design

### 1. Diagnostics

`scripts/dora_metrics.py` gains a per-repo pre-flight stage before measuring,
and maps every existing failure path onto the same structure. Each problem is
emitted as an entry in an `issues` list:

```json
{
  "code": "no_markers_matching_pattern",
  "impact": "partial",
  "message": "<raw text, unchanged from today when the code maps to an existing warning>",
  "evidence": { "tags_found": ["release-2026-07-01", "release-2026-07-14"] },
  "guidance": { "what": "...", "how_to_check": "...", "where_to_fix": "..." }
}
```

Codes:

| `code` | Detection | `impact` |
|---|---|---|
| `no_credential` | neither `GITHUB_TOKEN` nor `gh auth token` | `blocked` (root-level) |
| `repo_unreachable` | `GET /repos/{repo}` → 404/403 | `blocked` (that repo) |
| `token_unauthorized` | 401 on any call | `blocked` |
| `rate_limited` | 403 with rate limit | `blocked` |
| `branch_not_found` | `GET /repos/{repo}/branches/{prod_branch}` → 404 | `partial` |
| `no_markers_at_all` | repo has no Release (or tag, per `deploy_source`) | `partial` |
| `no_markers_matching_pattern` | markers exist, none match `tag_pattern`; evidence carries the first real names found | `partial` |
| `deploy_source_mismatch` | `deploy_source: release` with 0 Releases but matching tags exist, or the inverse | `partial` |
| `matching_releases_all_draft` | matching Releases exist, all draft | `partial` |
| `no_markers_in_window` | historical markers exist, none inside the window | `none` |
| `first_marker_no_prior` | existing warning | `partial` |
| `no_prs_in_range` | existing warning | `partial` |
| `pr_first_commit_unfetchable` | existing warning | `partial` |
| `github_api_error` | any other API failure; raw text only, no guidance entry | `blocked` |

Decisions:

- The field is **`impact`, not `severity`**: it describes whether the
  measurement succeeded, never whether a number is good. Values: `blocked`
  (nothing measurable at that level), `partial` (measured with a declared gap),
  `none` (factual note, nothing to fix).
- `branch_not_found` is `partial`, not `blocked`: Deployment Frequency does not
  depend on the branch, only Lead Time does.
- `warnings` stays as an array of strings, derived from `issues` — it is the
  verbatim contract the `report-writer` and the existing tests rely on.
- `no_markers_in_window` exists so a `0` is not mute. Its message states how
  many historical markers exist and the date of the latest, as raw data; its
  guidance says there is nothing to configure.
- Cost: 2 extra REST calls per repo (`/repos`, `/branches/{branch}`), outside
  the Search API, which is the rate-limited one.

### 2. Single source of truth for the steps

`references/troubleshooting.md` remains the only place the prose lives. It is
restructured to one entry per code, anchored and parseable:

```markdown
<!-- code: no_markers_matching_pattern -->
## The repo has Releases/tags but none match `tag_pattern`

### What
...

### How to check
...

### Where to fix
...
```

The current entries keep their text; the `**What.**` bold paragraphs become
`###` subsections so parsing is robust instead of brittle. The text-matching
instructions (matching on "has no known prior", placeholders `<Release|Tag>`,
`vX.Y.Z`, `#N`) are removed — codes replace them.

New module `scripts/troubleshooting.py`:

```python
load_guidance(path) -> dict[str, {"what": str, "how_to_check": str, "where_to_fix": str}]
```

Parses by `<!-- code: X -->` anchor, splits on `###`. No new dependencies. A
missing file or a code with no entry yields `None` for that code; the report
then shows the raw `message` plus `(no guidance for 'X' in troubleshooting.md)`.
It degrades visibly and never invents.

Flow:

1. The script detects a problem and builds the issue with its `code`.
2. Before serializing, it hydrates each issue's `guidance` from
   `troubleshooting.md`.
3. Both the stdout JSON and the saved `.json` carry the steps inline.
4. `format_human_summary` renders, per repo, a **"Problems found and how to fix
   them"** section listing the `blocked` and `partial` issues: the verbatim
   message, with What / How to check / Where to fix beneath it. Issues with
   `impact: none` render below it under **"Notes"**, same shape — they are
   context for a number, not problems. The saved `.md` is self-contained.
5. `agents/report-writer.md` stops doing lookup and text matching. Its rule
   becomes: render `issues[].guidance` exactly as the JSON provides it, and
   never write guidance that is not there. Chat and file therefore say the same
   thing, and the agent loses the ability to improvise remediation.

### 3. Total failures, exit codes

- **No credential no longer aborts.** `main()` builds the result with a
  root-level `issues` list (for global problems, not tied to a repo) holding a
  hydrated `no_credential`, renders the report, saves `.json`/`.md` when
  `--out-dir` is set, prints, and exits 1.
- **Invocation errors stay as they are** — `--branch` without `--project`, an
  invalid `deploy_source`: stderr plus exit 1, no report. These are user
  invocation mistakes, not repo findings.
- **Per-repo API failures** become coded issues instead of
  `{"repo", "error"}`. The other repos in the project are still measured.
- **Exit code:** 0 when nothing is `blocked`; 1 when at least one `blocked`
  issue exists at any level. `partial` issues do not change the exit code — the
  run measured, with declared gaps.

### 4. Tests

In `tests/test_dora_metrics.py`, matching the existing style:

- `troubleshooting.py` parser: well-formed entry, unknown code, missing file.
- **Drift test:** every code the script can emit has an entry in
  `troubleshooting.md`, and every entry maps to a code the script emits. Without
  it the single source of truth desynchronizes over time. `github_api_error` is
  the one deliberate exception (a catch-all with no fixed remediation) and lives
  in an explicit allowlist in the test, so the exception is visible rather than
  a hole.
- Each pre-flight check with a mocked session: repo 404, branch 404, no
  markers, markers not matching, all draft, `deploy_source` mismatch.
- Renderer: the `.md` includes the steps, and the verbatim message still appears
  intact above the guidance.
- No credential: a report and files are still produced, exit code is 1.

The E2E suite (`tests/e2e/run_e2e.py`) runs against real repos; it must keep
passing, but no cases are added to it.

## Files touched

| File | Change |
|---|---|
| `scripts/dora_metrics.py` | pre-flight diagnostics, `issues`, guidance hydration, renderer section, no-credential path, exit codes |
| `scripts/troubleshooting.py` | new — anchor parser |
| `references/troubleshooting.md` | restructured to code anchors + `###` subsections; entries for the new codes |
| `agents/report-writer.md` | renders `issues[].guidance` from the JSON; no lookup, no text matching |
| `assets/report-template.md` | example with the problems-and-steps section |
| `SKILL.md` | Step 3 (auth no longer aborts), Step 5 (report rules) |
| `README.md` | output example with `issues` |
| `tests/test_dora_metrics.py` | tests above |
