---
name: bump-tailcat
description: Check upstream tailcat for a newer version than the one rtailcat pins, review what changed in the C ABI and related code, trial the new version against the package, propose and apply fixes for anything it breaks, and pin the new version once the package is green. Use when asked to bump, update, upgrade, or re-pin tailcat, to check for a new tailcat release, or to see whether an upstream fix has landed.
argument-hint: "[release | commits | <tag, branch, or sha>]"
---

# Bump the pinned tailcat version

rtailcat builds upstream tailcat's C ABI (`cmd/libtailcat`) from a version pinned in `src/go/go.mod` (and again in `tests/relay/go.mod` for the test relay). This skill moves that pin safely: review first, trial on a branch, fix what breaks, and only then make the new pin final.

Read `CLAUDE.md` before starting. It has the architecture, build modes, test commands, conventions, and the Known issues list. Follow its conventions for any code or docs you touch.

## Arguments

- no argument or `release`: target the latest upstream release (the default).
- `commits`: target the head of upstream `main`.
- anything else: treat it as an explicit tag, branch, or commit sha.

## Rules

- The pin in the working tree stays untouched until step 6. All trial work happens on a branch.
- Never commit, push, or open a pull request unless the user asks. Offer at the end.
- Use the AskUserQuestion menu for every decision that is the user's (anything that changes the public R API, has more than one reasonable fix, or drops a feature). Put the recommended option first. Apply mechanical fixes without asking.
- Do not work around upstream bugs in the package unless the user says to. Document them (see step 5).
- Report honestly: if a step fails or was skipped, say so with the output.

## Step 1: Find the current pin and the candidate

Current pin:

```sh
awk '$1 == "github.com/tailscale/tailcat" {print $2}' src/go/go.mod
```

A pseudo-version such as `v0.7.1-0.20261105151022-e00cdde6ff78` ends in the short commit sha; a plain tag such as `v0.8.0` is a release. Resolve it to a full sha with `gh api repos/tailscale/tailcat/commits/<sha-or-tag> --jq .sha`.

Candidate:

- release mode: `gh api repos/tailscale/tailcat/releases/latest --jq '.tag_name + " " + .published_at'`
- commits mode: `gh api repos/tailscale/tailcat/commits/main --jq '.sha + " " + .commit.committer.date'`
- explicit ref: resolve it the same way.

Then check, in this order, and stop with a clear explanation if any fails:

1. The candidate contains the C ABI: `gh api "repos/tailscale/tailcat/contents/cmd/libtailcat/tailcat.h?ref=<candidate>" --jq .name`. Releases up to v0.7.0 do not; the ABI was added on upstream main on 2026-10-07.
2. The candidate is ahead of the current pin: `gh api repos/tailscale/tailcat/compare/<current>...<candidate> --jq '.status + " ahead_by=" + (.ahead_by|tostring)'`. `identical` means nothing to do. `behind` or `diverged` means the candidate is older than or not a descendant of the pin; in release mode this means no release has caught up with the pinned commit yet. Say so, mention that `commits` mode exists, and stop unless the user explicitly wants a downgrade.

## Step 2: Review what changed upstream

Get the file list and commits between the two versions with the compare API (paginate if needed), and read the changelog entries for the range. Then diff the files that matter to this package, fetching both versions (`gh api repos/tailscale/tailcat/contents/<path>?ref=<ref> --jq .content | base64 -d`), or use a scratch clone outside the project if the range is large.

Read these closely, in priority order:

| Upstream path                         | Why it matters here                                                                                   |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `cmd/libtailcat/tailcat.h`            | The ABI contract. Any change to a signature, status code, JSON field, or documented semantics         |
| `cmd/libtailcat/main.go`, `*.def`     | Exported functions added, removed, or renamed                                                         |
| `internal/capi/`                      | Behavior behind the ABI, including fixes for bugs listed in Known issues                              |
| `internal/capitest/`                  | The local relay the test suite builds and runs (flags, output format)                                 |
| `wire.go`, address code in `tailcat.go` | Address format, which the tests decode and hand-build                                               |
| `go.mod`                              | The `go` line (minimum Go version, feeds `SystemRequirements`) and dependency changes                 |
| `build-tags.txt`                      | Build tags the Makevars rule reads                                                                    |
| `CHANGELOG.md`                        | Upstream's own summary, including breaking changes                                                    |

Classify every relevant change as one of: ABI version change (`tc_abi_version`), breaking change to an existing call, behavior change, new capability the package could wrap, fix for a known issue, build or toolchain change, or irrelevant to this package.

Cross-check against `CLAUDE.md` Known issues and `notes/upstream_issues.md` (if present): for each listed upstream bug, say whether the range appears to fix it.

Give the user a short summary of the review before changing anything: versions, what is breaking, what is new, which known issues look fixed, and what you expect to have to change in the package. If the review shows the bump is not worthwhile or is risky, say so and ask whether to continue.

## Step 3: Prepare a trial branch

- Run `git status --short`. If there are uncommitted changes, stop and ask the user how to proceed; do not stash or discard anything yourself.
- Ask whether to do the trial on a new branch named `bump-tailcat-<short ref>` (recommended) or in place on the current branch. Create the branch only after the user agrees.
- Check that the installed Go satisfies the candidate's `go` line. If not, tell the user what version is needed and stop.

## Step 4: Trial the new version

Apply the candidate on the trial branch and rebuild from clean:

```sh
tools/update-tailcat.sh <candidate>
./cleanup
R CMD INSTALL .
Rscript -e 'cpp11::cpp_register(); devtools::document()'
```

Then run, capturing output:

```sh
Rscript -e 'devtools::test()'
RTAILCAT_TEST_RELAY=public Rscript -e 'devtools::test()'
R CMD build . && R CMD check --no-manual rtailcat_*.tar.gz
```

Expectations to compare against (see `CLAUDE.md` for the current baseline): the suite passes in local-relay mode, and `R CMD check` reports only the one expected warning about the Go runtime's `stderr`/`abort`/`exit` references. Remove the built tarball and check directory afterwards, and make sure no relay process is left running.

Tests that pin a known upstream bug are written to fail when upstream fixes it. A failure there is good news: handle it in step 5.

## Step 5: Diagnose and correct

For each build error, test failure, new warning, or behavior the review flagged, decide which it is:

- upstream changed behavior on purpose: adapt the package (native layer, R layer, docs, tests) to the new contract;
- upstream fixed a known issue: remove the pinning test's TODO and assert the correct behavior, delete the entry from `CLAUDE.md` Known issues, and mark it resolved in `notes/upstream_issues.md` with the fixing commit;
- upstream introduced a bug: do not work around it by default; add a pinning test with a TODO, add it to Known issues and to `notes/upstream_issues.md` in the same format as the existing entries, and tell the user;
- the package or a test relied on something the ABI never promised: fix the package or the test;
- the local test relay changed: update `tests/testthat/helper-relay.R` and `setup-relay.R`.

Also handle what the review found even if no test failed: new ABI calls or fields (propose wrapping them, as a menu question), changed header wording that the R docs paraphrase, a changed minimum Go version, and any deliberate departure from the C ABI that the R docs describe.

Propose the full set of corrections to the user before large changes. Ask a menu question wherever there is a real choice. Then apply the corrections and rerun step 4's checks until they are clean. Every behavior fix needs a test.

If the corrections are larger than the user wants to take on now, offer to abandon the trial: switch back to the original branch and delete the trial branch, only with the user's agreement.

## Step 6: Make the pin final

Only when the suite and `R CMD check` are clean on the trial branch:

- Confirm `src/go/go.mod` and `tests/relay/go.mod` name the same tailcat version, and that `DESCRIPTION` `SystemRequirements` matches the `go` line.
- Replace the old commit sha everywhere it is referenced: `git grep -n <old short sha>` and `git grep -n <old full sha>` across the repository, plus `notes/` (which is git-ignored, so search it directly). This includes documentation links to `tailcat.h` at the pinned commit.
- Update `CLAUDE.md` (pinned version, Known issues, anything the bump changed), `README.md` if user-visible behavior changed, and `inst/COPYRIGHTS` if upstream's dependency set or licenses changed.
- If `src/go/vendor/` exists, the update script has already refreshed it; confirm a vendored build still works.
- Run the full suite one last time.

## Step 7: Report

Tell the user, in this order: the old and new pinned versions; what changed upstream that mattered; what was corrected in the package and why; known issues resolved or added; the final test and check results with real numbers; anything not verified (Linux and Windows builds are untested); and any decisions still open. Then offer to commit the result (one concise message, on the trial branch) and, if they want, to merge it.
