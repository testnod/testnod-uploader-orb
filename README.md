# TestNod Uploader Orb

[![CircleCI Orb Version](https://badges.circleci.com/orbs/testnod/testnod-uploader.svg)](https://circleci.com/developer/orbs/orb/testnod/testnod-uploader) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/testnod/testnod-uploader-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

Upload JUnit XML test reports to [TestNod](https://testnod.com) from CircleCI, and finalize the test run once all results are in. Add the `upload` command to a job that produces a JUnit XML file — it uploads even if a prior test step failed, and reads CI metadata (branch, commit SHA, run URL, build id) automatically from CircleCI's built-in environment variables.

See [`src/README.md`](src/README.md) for how the orb source is organized, and [`src/examples`](src/examples) for usage examples (single job, parallel shards, fan-out across jobs).

## Plan limits and paused uploads

Each `build_id` that TestNod finishes processing counts as one test run toward your plan's monthly limit. By default every container and job in a workflow shares `$CIRCLE_WORKFLOW_ID`, so a parallel or fan-out build counts once. Give shards their own `build_id` only if you want them as separate runs, since each one then counts. See [Plans and billing](https://testnod.com/docs/administration/plans-and-billing).

TestNod refuses an upload with `403 Forbidden` when uploads are paused for your organization (well over the plan's monthly limit) or for the project (an inactive project on the Solo plan). Nothing is recorded, and the upload isn't retried. The step log shows TestNod's reason, for example:

```
Error creating test run on TestNod: 403 Forbidden: This project is paused because the Solo plan includes 1 project and another project in your organization is active. ...
```

- The step fails, the same as with a wrong project token. With `ignore_failures: true` it prints a warning and the job carries on.
- With parallel or fan-out builds, every shard gets the `403`.
- A separate `finalize: "only"` job then gets `404 Test run not found` because no run exists. Its log points back to the upload jobs for the reason.

See [troubleshooting](https://testnod.com/docs/sending-test-results/troubleshooting#i-get-a-403-from-the-upload-endpoint) for how uploads resume. Showing TestNod's reason needs uploader v0.1.1 or later (`uploader_version: latest`, the default, already is).

---

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/testnod/testnod-uploader) - The official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orbs/use/orb-intro/) - Docs for using, creating, and publishing CircleCI Orbs.

### How to Contribute

We welcome [issues](https://github.com/testnod/testnod-uploader-orb/issues) and [pull requests](https://github.com/testnod/testnod-uploader-orb/pulls) against this repository!

### Testing

Every pipeline tests the orb against a mock TestNod server (`test/mock_server.py`) and checks the recorded requests with `test/expect.py`. No requests go to testnod.com.

- **Script tests** (`.circleci/config.yml`): `test/run-tests.sh` runs `src/scripts/upload.sh` through each scenario: upload and finalize, each `finalize` mode, custom token variable, `retry`, tag-triggered pipelines, a missing results file, a missing token or `file` parameter, server errors, a paused organization or project (`403`), a finalize that finds no test run, a concurrent upload conflict (`409`), an unreachable server, `ignore_failures`, a pinned version, `latest`, and a version that doesn't exist. Runs on x86_64 and ARM64.
- **Orb tests** (`.circleci/test-deploy.yml`): run the packed orb's `upload` command and `upload` job, checking that parameters and CircleCI metadata reach TestNod, and that a pinned uploader is restored from the cache.

To run the script tests locally (needs bash, curl and python3):

```sh
test/run-tests.sh
```

### How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info testnod/testnod-uploader | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/testnod/testnod-uploader-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.

### Development Orbs

Prerequisites:

- An initial semver deployment must be performed in order for Development orbs to be published and seen in the [Orb Registry](https://circleci.com/developer/orbs).

A [Development orb](https://circleci.com/docs/orbs/use/orb-concepts/#development-orbs) can be created to help with rapid development or testing. To create a Development orb, change the `orb-tools/publish` job in `test-deploy.yml` to be the following:

```yaml
- orb-tools/publish:
    orb_name: testnod/testnod-uploader
    vcs_type: github
    pub_type: dev
    # Ensure this job requires all test jobs and the pack job.
    requires:
      - orb-tools/pack
      - command-test
      - cache-test
      - job-test
    context: testnod-publishing
    filters: *filters
```

The job output will contain a link to the Development orb Registry page. The parameters `enable_pr_comment` and `github_token` can be set to add the relevant publishing information onto a pull request. Please refer to the [orb-tools/publish](https://circleci.com/developer/orbs/orb/circleci/orb-tools#jobs-publish) documentation for more information and options.
