---
name: release
description: Cut a new testnod/testnod-uploader orb version — pick the next semver tag, run pre-release gates, commit the CHANGELOG release entry, create a signed tag, push only when every gate passes and the user confirms, then watch the CircleCI publish job and create the GitHub Release. Use when the user asks to release, bump the version, tag, or publish the orb.
argument-hint: "[patch|minor|major|vX.Y.Z]"
disable-model-invocation: true
---

# Release the testnod-uploader orb

The version lives in the git tag; there is no version field in `src/`. `CHANGELOG.md` keeps an `## [Unreleased]` section, and a release turns it into `## [vX.Y.Z] - YYYY-MM-DD` in a `Release vX.Y.Z` commit on `main` (step 5). The tag goes on that commit. Pushing a tag that matches `^v[0-9]+\.[0-9]+\.[0-9]+$` runs the CircleCI setup workflow (`.circleci/config.yml`) and then `test-deploy` (`.circleci/test-deploy.yml`), whose last job, `orb-tools/publish`, publishes `testnod/testnod-uploader@X.Y.Z` to the CircleCI Orb Registry with `pub_type: production`.

Published orb versions are **immutable and can't be deleted**. Consumers pin ranges (the examples use `@1.0`), so every project on `@1` or `@1.0` picks up the new version on its next pipeline. There's no rollback short of cutting another release. Treat the push as a production deploy.

Requested bump: `$ARGUMENTS` (if empty, recommend one in step 3).

## 1. Gather state

Run these and keep the output. Don't make any changes yet.

```bash
git fetch origin --tags
git status --porcelain
git rev-parse --abbrev-ref HEAD
git rev-list --left-right --count origin/main...HEAD      # behind / ahead
LAST=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*')
git log --oneline "$LAST"..HEAD
git diff --stat "$LAST"..HEAD
circleci orb info testnod/testnod-uploader | grep Latest
sed -n '/^## \[Unreleased\]/,/^## \[v/p' CHANGELOG.md
```

## 2. Gates: when NOT to release

Go through every gate. A **STOP** means: say why, suggest the fix, and end without committing or tagging. A **CONFIRM** means: explain the risk, then ask the user with AskUserQuestion before going on. Don't try to fix a STOP yourself unless the user asks.

**Repository state: STOP if any of these fail**
- The current branch isn't `main`.
- The working tree has uncommitted or untracked changes.
- `HEAD` is ahead of `origin/main`. Unpushed commits would go out without CI having run on them. Ask the user to push main first and wait for CI.
- `HEAD` is behind `origin/main`. You'd be releasing a stale commit.
- The target tag already exists, locally or on `origin` (`git ls-remote --tags origin vX.Y.Z`). **Never** delete, move, or force-push an existing version tag. Choose the next version.

**Registry state: STOP if it doesn't match**
- The registry's `Latest` (`circleci orb info`) must equal `$LAST` without the `v`. If the registry is behind, the last tag never published; find out why (its `orb-tools/publish` job) before stacking another release on it. If the registry is ahead, a version was published outside this flow.

**Nothing to ship: STOP**
- There are no commits since `$LAST`.
- Nothing that ships in the orb changed since `$LAST`:
  ```bash
  git diff --quiet "$LAST"..HEAD -- src
  ```
  If that exits 0, only CI config, tests, the root README, CHANGELOG, or `.claude/` changed. A new tag would republish the same orb under a new number, so say that and stop. (Everything under `src/` counts, including `src/examples` and descriptions: they show on the registry page.)
- The `[Unreleased]` section of `CHANGELOG.md` is missing or empty. Ask the user to write the entries first; don't draft them yourself unless asked.

**Verification: STOP if any of these fail.** This mirrors `.circleci/config.yml`. Pack into the scratchpad, not the repo:
```bash
yamllint src
shellcheck src/scripts/*.sh test/*.sh
circleci orb pack src > <scratchpad>/orb.yml && circleci orb validate <scratchpad>/orb.yml
test/run-tests.sh
```
`test/run-tests.sh` needs port 8765 free, downloads the uploader from releases.testnod.com, and clears `/tmp/testnod-uploader`.

- Check CI on the exact commit. CircleCI reports GitHub commit statuses, not Actions runs:
  ```bash
  gh api "repos/testnod/testnod-uploader-orb/commits/$(git rev-parse HEAD)/status" \
    --jq '{state, statuses: [.statuses[] | {context, state}]}'
  ```
  STOP if `state` is `failure`/`error`, or `pending` with statuses still running. If there are no statuses at all, or `gh` isn't available, treat it as a CONFIRM. The `orb-tools/review` job only runs in CI, so a green local run doesn't replace it.

**Risky content: CONFIRM each one that applies**
- **Breaking orb interface.** Diff the orb's public surface: `git diff "$LAST"..HEAD -- src/commands src/jobs src/executors`. A removed or renamed command, job, executor, or parameter, a changed parameter `type` or `default`, a removed `enum` value, or a newly required parameter breaks consumers on `@1`/`@1.0`. That needs a **major** bump; list what changed and recommend major or holding the release.
- **Uploader dependency.** `uploader_version` defaults to `latest`. If `src/scripts/upload.sh` passes a new flag to the uploader binary, the uploader release that adds that flag must already be published to `latest/`, or every default-config upload fails. Name the flag and ask whether that uploader release is out. Pinned uploader versions that predate the flag should be called out in the parameter description and CHANGELOG.
- **TestNod API changes.** If `upload.sh` changes the finalize request (endpoint, headers, body), ask whether the matching TestNod webapp change is **deployed to production**.
- **Release pipeline changed.** If `git diff --quiet "$LAST"..HEAD -- .circleci` shows changes, this is the first run of the edited pipeline, and its last job publishes to production. Summarize what changed (especially the `orb-tools/publish` job, `release-filters`, and the `requires` list) and confirm.
- **CHANGELOG coverage.** Compare the `[Unreleased]` entries with the commits and the `src/` diff. If a user-visible change isn't listed, point it out and ask whether to add it.

## 3. Choose the version

Tags are `vMAJOR.MINOR.PATCH` with no pre-release suffix: anything else doesn't match `release-filters` and won't publish. Recommend a bump from the `src/` changes since `$LAST`:
- **patch**: bug fixes, description and example fixes, internal script changes with no new behavior.
- **minor**: new parameters (with defaults that keep current behavior), new commands, jobs, or examples.
- **major**: any breaking interface change from step 2. Never recommend a major bump without that, and confirm it explicitly with the user.

If `$ARGUMENTS` is an explicit `vX.Y.Z`, check that it's valid semver and strictly greater than `$LAST`. If it isn't, STOP. If it understates the change (a patch with new parameters, a minor with breaking changes), say so and recommend the right bump.

## 4. Summarize and confirm

Show the user one summary:
- `$LAST` → new version, and the commit SHA the release commit will build on
- The commits included (one line each)
- The result of every gate, with any CONFIRM items called out
- The release commit's changes (step 5): the CHANGELOG heading rename and, on a minor or major bump, the example pin update
- Draft release notes. They become the GitHub Release body in step 8. Base them on the `[Unreleased]` entries, and lead with anything a user has to change in their config. Say compatibility breaks plainly.

Then ask with AskUserQuestion: **Commit, tag, and push** / **Commit and tag locally only** / **Cancel**. Prior approval in the conversation doesn't count. Ask every time.

## 5. Release commit

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [vX.Y.Z] - $(date +%F)`. Don't add a new empty `[Unreleased]` section; the next change adds it.
2. On a minor or major bump, update the orb pin in each `src/examples/*.yml` (`testnod/testnod-uploader@1.0`) to the new `MAJOR.MINOR`, so the registry examples cover the new features. Leave the pin alone on a patch bump.
3. Commit only those files with the message `Release vX.Y.Z`. Commits are signed by the user's git config; if signing fails, don't bypass it. Give the user the command to run themselves with `!`.

## 6. Tag and push

Create a signed, annotated tag on the release commit, with the version as the message:
```bash
git tag -s vX.Y.Z -m vX.Y.Z
git tag -v vX.Y.Z
```
If signing fails (for example, no pinentry in a non-interactive shell), don't fall back to an unsigned tag. Give the user the command to run themselves: `! git tag -s vX.Y.Z -m vX.Y.Z`.

Only if the user chose to push, push `main` first, then **only that tag**:
```bash
git push origin main
git push origin vX.Y.Z
```
Never use `--tags` (it would push stray local tags) and never `--force`. If the `main` push is rejected (someone pushed meanwhile), STOP before pushing the tag: delete the **local, unpushed** tag and release commit only with the user's OK, and start over from step 1.

If the user chose local only, tell them the two push commands and that pushing `main` and the tag later still publishes.

## 7. Watch the publish

This step and step 8 need `gh`, installed and authenticated (`gh auth status`). Without it, give the user the pipelines URL (`https://app.circleci.com/pipelines/github/testnod/testnod-uploader-orb`), the release notes, and the step 8 command to run themselves, then stop.

The tag pipeline posts statuses to the release commit. `ci/circleci: orb-tools/publish` only runs for the tag, after every test job passes. Poll it in the background (`run_in_background`), for up to ~30 minutes:
```bash
SHA=$(git rev-parse 'vX.Y.Z^{commit}')
for _ in $(seq 1 60); do
  out=$(gh api "repos/testnod/testnod-uploader-orb/commits/$SHA/status" \
    --jq '.statuses[] | "\(.state) \(.context) \(.target_url)"')
  if grep -qE '^success ci/circleci: orb-tools/publish ' <<<"$out"; then echo "PUBLISHED"; echo "$out"; exit 0; fi
  if grep -qE '^(failure|error) ' <<<"$out"; then echo "FAILED"; echo "$out"; exit 1; fi
  sleep 30
done
echo "TIMEOUT"; echo "$out"; exit 2
```
Tell the user the result either way, with the CircleCI job link (`target_url`).

- On success, confirm the registry: `circleci orb info testnod/testnod-uploader | grep Latest` must show `X.Y.Z`. Link https://circleci.com/developer/orbs/orb/testnod/testnod-uploader.
- On failure, nothing was published unless `orb-tools/publish` itself succeeded. A flaky job can be rerun from the CircleCI UI for the same tag; that's the user's call. For a real failure, fix forward with a new patch release. Never move or re-push the tag.
- Don't try the published orb in a real project yourself. Hand verification back to the user.

## 8. GitHub Release

Only once `orb-tools/publish` has **passed** and the registry shows the new version. Skip this step if the tag was only created locally.

1. Read the current latest release as the template: `gh release view --json tagName,name,body`. Match its format: the title is the bare version (`vX.Y.Z`), the body opens with `## What's new` and a one-line summary, then `###` sections (such as `New`, `Fixes`, `Maintenance`) with short bullets.
2. Draft the notes in that format from the step 4 draft. Write them to a file in the scratchpad, not the repo.
3. Show the notes and ask with AskUserQuestion: **Publish release** / **Edit notes** / **Skip**. A GitHub Release is public, so ask even though the tag push was already approved.
4. Create the release on the existing tag and mark it latest. `--verify-tag` stops `gh` from creating a new tag if the name is wrong.
   ```bash
   gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file <notes.md> --latest
   gh release list --limit 3
   ```
   Confirm `vX.Y.Z` shows as `Latest`, and link the release URL in the final report.
