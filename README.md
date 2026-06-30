# TestNod Uploader Orb

[![CircleCI Orb Version](https://badges.circleci.com/orbs/testnod/testnod-uploader.svg)](https://circleci.com/developer/orbs/orb/testnod/testnod-uploader)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

Upload JUnit XML test results to [TestNod](https://testnod.com) for tracking,
flaky-test detection, and alerting — straight from your CircleCI pipelines.

## Prerequisites

1. A [TestNod](https://testnod.com) account and a project **API token**.
2. Expose the token to your pipeline as an environment variable. A
   [CircleCI context](https://circleci.com/docs/contexts/) is recommended:

   ```
   Organization Settings → Contexts → create "testnod" → add TESTNOD_TOKEN
   ```

   By default the orb reads the token from the env var named `TESTNOD_TOKEN`.
   You pass the **name** of the variable, never the secret value itself.

## Quick start

```yaml
version: 2.1

orbs:
  testnod-uploader: testnod/testnod-uploader@1.0

jobs:
  test:
    docker:
      - image: cimg/ruby:3.3
    steps:
      - checkout
      - run:
          name: Run tests
          command: bundle exec rspec --format RspecJunitFormatter --out test-results/rspec.xml
      # Add one step after your tests. `when: always` is built in, so results
      # upload even when the tests fail.
      - testnod-uploader/upload:
          file: test-results/rspec.xml
          tags: "rspec, unit"

workflows:
  test-and-upload:
    jobs:
      - test:
          context: testnod
```

## The `upload` command

Add `testnod-uploader/upload` as a step to any job that produced a JUnit XML
file. This is the primary interface.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `token` | `env_var_name` | `TESTNOD_TOKEN` | **Name** of the env var holding your API token (not the value). |
| `file` | `string` | `""` | Path to the JUnit XML file. Required unless `finalize` is `"only"`. |
| `tags` | `string` | `""` | Comma-separated tags; whitespace is trimmed. |
| `ignore_failures` | `boolean` | `false` | Don't fail the job on uploader/finalize errors. |
| `uploader_version` | `string` | `latest` | Uploader binary version. Pinned versions are cached. |
| `build_id` | `string` | `""` | Groups shards into one run. Defaults to `$CIRCLE_WORKFLOW_ID`. |
| `finalize` | `enum` | `"true"` | `"true"` upload + finalize, `"false"` upload only, `"only"` finalize only. |

The run step uses `when: always`, so a failing test step earlier in the job
does **not** skip the upload. If `file` is set but the file does not exist (e.g.
a step before your tests failed), the upload is **skipped, not failed**.

## The `upload` job

A thin wrapper that runs the command on the parameterized `default` executor.
It takes the same parameters as the command, plus `executor_tag` (the
`cimg/base` image tag), and defaults `finalize` to `"only"` — because its most
common use is a finalize aggregator after parallel/fan-out uploads.

## Parallel tests (CircleCI `parallelism`)

Each container uploads its slice with `finalize: "false"`; a separate job
finalizes once. They share `$CIRCLE_WORKFLOW_ID`, so they group into one run.

```yaml
workflows:
  test-and-upload:
    jobs:
      - test:                       # parallelism: 4, uploads with finalize: "false"
          context: testnod
      - testnod-uploader/upload:
          name: finalize-testnod
          context: testnod
          finalize: "only"
          requires:
            - test
```

See the **parallel_shards** and **fan_out_finalize**
[usage examples](https://circleci.com/developer/orbs/orb/testnod/testnod-uploader#usage-examples)
for full configs (including the per-container test step).

## Platform support

v1 targets **Linux** (the `default` executor uses `cimg/base`). The `upload`
command also runs unmodified inside a macOS executor (the script detects
`darwin`/`arm64`). Windows is not supported in v1.

## Advanced

- **Finalize API base URL**: set `TESTNOD_BASE_URL` as an environment variable
  to override `https://testnod.com` (e.g. for staging).
- **Caching**: pinned `uploader_version`s are cached per OS/arch via
  `save_cache`/`restore_cache`; `latest` always re-downloads.

## Contributing / development

This orb uses the [Orb Development Kit](https://circleci.com/docs/orb-development-kit/)
with a decomposed source layout:

```
src/
├── @orb.yml            # orb metadata (description, display URLs)
├── commands/upload.yml # the upload command
├── jobs/upload.yml     # the standalone job
├── executors/default.yml
├── examples/           # usage examples (rendered in the registry)
└── scripts/upload.sh   # the shell logic (included via <<include>>)
```

```bash
# Lint + pack locally
circleci orb pack src > orb.yml
circleci orb validate orb.yml

# Lint the shell
shellcheck src/scripts/upload.sh
```

CI lints, packs, runs integration tests against a real TestNod test project, and
publishes a production release when a `vX.Y.Z` tag is pushed. See
`.circleci/config.yml` and `.circleci/test-deploy.yml`.

## License

[MIT](./LICENSE)
