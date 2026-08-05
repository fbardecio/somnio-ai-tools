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
