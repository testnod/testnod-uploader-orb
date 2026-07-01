# Changelog

All notable changes to the `testnod/testnod-uploader` orb are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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
