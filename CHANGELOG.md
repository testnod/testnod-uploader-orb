# Changelog

All notable changes to the `testnod/testnod-uploader` orb are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- When TestNod refuses an upload, for example with a `403` because uploads are
  paused for the organization or project, the step now ends with an error that
  points to the uploader's output, where TestNod's reason is printed. Needs
  uploader v0.1.1 or later (`latest` already is).
- With `ignore_failures: true`, a failed upload no longer leads to a second,
  misleading finalize warning. Finalize now says there's nothing to finalize
  because the upload failed.
- A `finalize: "only"` job that finds no test run now explains that the upload
  jobs may have been refused, and points to their logs.
- Finalize errors show TestNod's `error_message` instead of the raw JSON body.
- Finalize waits 5 seconds between retries instead of 2, to get past TestNod's
  per-minute rate limit.
- `ignore_failures` description: it also covers paused uploads.
- README: new "Plan limits and paused uploads" section.
- CI: tests pin uploader v0.1.1, and cover both `403` responses, a finalize
  that finds no test run, and a `409` that's retried.

## [v1.1.0] - 2026-10-21

### Added

- `retry` parameter on the `upload` command and job (boolean, default
  `false`). When `true`, the upload is marked as a rerun of tests that failed
  earlier in the same build: the uploader gets `-retry` and sends a top-level
  `"retry": true`. Needs uploader v0.1.0 or later (`latest` already is).

### Changed

- CI: tests pin uploader v0.1.0 instead of v0.0.6.

## [v1.0.1] - 2026-10-03

### Fixed

- `ignore_failures: true` now also covers a finalize request that can't reach
  TestNod at all, instead of failing the job.
- `ignore_failures: true` is honored when the boolean reaches the script as
  `1` instead of `true`.

### Changed

- `fan_out_finalize` example now uses `cimg/node:24.21` (Node 20 is end-of-life).
- Updated CircleCI docs links in the READMEs to their current locations.
- CI: bumped `circleci/orb-tools` to 12.5 (CircleCI CLI v1 support) and
  `circleci/shellcheck` to 3.4.
- CI: tests against a mock TestNod server (`test/run-tests.sh` for the upload
  script, plus orb-level tests in `test-deploy.yml`), on x86_64 and ARM64.

## [v1.0.0] - 2026-07-01

### Added

- Initial release of the `testnod/testnod-uploader` orb.
- `upload` command: download the TestNod uploader, upload a JUnit XML report,
  and optionally finalize the run. Uses `when: always` so results upload even
  after a failing test step.
- `upload` job: thin wrapper around the command on a parameterized `default`
  executor, defaulting to `finalize: "only"` for finalize-aggregation jobs.
- `default` executor: parameterized `cimg/base` image tag.
- Usage examples: `single_job`, `parallel_shards`, `fan_out_finalize`.
- Token handled via `env_var_name` (the env var's name is passed, never the
  secret value).
- Caching of pinned uploader versions per OS/arch.
