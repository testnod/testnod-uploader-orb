# Changelog

All notable changes to the `testnod/testnod-uploader` orb are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
