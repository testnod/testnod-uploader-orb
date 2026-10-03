#!/usr/bin/env bash
# Runs src/scripts/upload.sh through every scenario against the mock TestNod
# server (test/mock_server.py), then checks the recorded requests with
# test/expect.py. No requests go to testnod.com; the uploader binary itself is
# still downloaded from releases.testnod.com.
#
# The orb's `upload` command only passes its parameters to the script as
# environment variables, so each scenario sets those variables directly, along
# with the CircleCI built-ins the script reads. The orb wiring itself (parameters,
# cache steps, the `upload` job) is tested in .circleci/test-deploy.yml.
#
# Requires bash, curl and python3. Run from anywhere:
#   test/run-tests.sh
#
# Note: the script stores the uploader binary in /tmp/testnod-uploader, so this
# deletes that directory before the first scenario and before each download
# scenario.
set -euo pipefail

cd "$(dirname "$0")/.."

MOCK_PORT=8765
MOCK_URL="http://127.0.0.1:${MOCK_PORT}"
UPLOADER_VERSION="${UPLOADER_VERSION:-v0.0.6}"
UPLOADER_DIR="/tmp/testnod-uploader"
TMP_DIR=$(mktemp -d)
OUTPUT="${TMP_DIR}/output.log"
PASSED=0
FAILED=()

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if curl -fsS "${MOCK_URL}/__requests" > /dev/null 2>&1; then
  echo "ERROR: something is already listening on ${MOCK_URL}. Stop it and try again." >&2
  exit 1
fi

python3 test/mock_server.py --port "$MOCK_PORT" < /dev/null > "${TMP_DIR}/mock-server.log" 2>&1 &
MOCK_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS "${MOCK_URL}/__requests" > /dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -fsS "${MOCK_URL}/__requests" > /dev/null 2>&1; then
  echo "ERROR: mock TestNod server didn't start." >&2
  cat "${TMP_DIR}/mock-server.log" >&2
  exit 1
fi

rm -rf "$UPLOADER_DIR"

# Clears recorded requests and makes the mock server answer normally again.
reset_mock() {
  curl -fsS -X DELETE "${MOCK_URL}/__requests" > /dev/null
}

# Makes the mock server answer every API request with the given status.
fail_mock() {
  curl -fsS -X POST -d "{\"status\": $1}" "${MOCK_URL}/__fail" > /dev/null
}

# Runs upload.sh with the orb command's defaults plus CircleCI built-ins.
# Arguments are extra VAR=value overrides. Output goes to $OUTPUT and the exit
# status to $STATUS.
run_upload() {
  set +e
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    TESTNOD_BASE_URL="$MOCK_URL" \
    TESTNOD_TOKEN=test-token \
    TESTNOD_TOKEN_NAME=TESTNOD_TOKEN \
    TESTNOD_FILE=test/fixtures/results.xml \
    TESTNOD_TAGS="" \
    TESTNOD_IGNORE_FAILURES=false \
    TESTNOD_UPLOADER_VERSION="$UPLOADER_VERSION" \
    TESTNOD_BUILD_ID="" \
    TESTNOD_FINALIZE=true \
    CIRCLE_BRANCH=test-branch \
    CIRCLE_SHA1=0123456789abcdef \
    CIRCLE_BUILD_URL=https://circleci.com/gh/testnod/testnod-uploader-orb/42 \
    CIRCLE_WORKFLOW_ID=test-workflow-id \
    "$@" \
    bash src/scripts/upload.sh > "$OUTPUT" 2>&1
  STATUS=$?
  set -e
}

expect_status() {
  if [ "$STATUS" != "$1" ]; then
    echo "expected exit status $1, got ${STATUS}"
    return 1
  fi
}

expect_output() {
  if ! grep -qF -- "$1" "$OUTPUT"; then
    echo "expected output to contain: $1"
    return 1
  fi
}

expect_requests() {
  python3 test/expect.py --url "$MOCK_URL" "$@"
}

# Runs one scenario function and records whether it passed. Every scenario
# starts with a clean mock server.
scenario() {
  local name="$1"
  shift
  echo "--- ${name}"
  reset_mock
  # Not inside an `if`: errexit is ignored in conditions, even in a subshell
  local status
  set +e
  (set -e; "$@")
  status=$?
  set -e
  if [ "$status" = 0 ]; then
    PASSED=$((PASSED + 1))
  else
    echo "FAILED: ${name}"
    echo "Script output:"
    sed 's/^/  | /' "$OUTPUT"
    FAILED+=("$name")
  fi
}

# --------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------

upload_and_finalize() {
  run_upload TESTNOD_TAGS=" ci , rspec,,nightly"
  expect_status 0
  expect_output "Test run finalized."
  test -x "${UPLOADER_DIR}/$(binary_name)" || { echo "expected uploader binary at ${UPLOADER_DIR}/$(binary_name)"; return 1; }
  expect_requests \
    --count upload=1 --count presigned=1 --count finalize=1 --count upload_failed=0 \
    --equals "upload.headers.project-token=test-token" \
    --equals 'upload.body.tags=[{"value": "ci"}, {"value": "rspec"}, {"value": "nightly"}]' \
    --equals "upload.body.test_run.metadata.branch=test-branch" \
    --equals "upload.body.test_run.metadata.commit_sha=0123456789abcdef" \
    --equals "upload.body.test_run.metadata.run_url=https://circleci.com/gh/testnod/testnod-uploader-orb/42" \
    --equals "upload.body.test_run.metadata.build_id=test-workflow-id" \
    --body-file presigned=test/fixtures/results.xml \
    --equals "finalize.headers.project-token=test-token" \
    --equals "finalize.body.build_id=test-workflow-id"
}

cached_binary() {
  # The previous scenario left the pinned binary in place, like restore_cache does
  run_upload
  expect_status 0
  expect_output "Using cached TestNod uploader"
  expect_requests --count upload=1 --count presigned=1 --count finalize=1
}

custom_token_name() {
  run_upload TESTNOD_TOKEN= TESTNOD_TOKEN_NAME=MY_TESTNOD_TOKEN MY_TESTNOD_TOKEN=other-token
  expect_status 0
  expect_requests \
    --count upload=1 --count finalize=1 \
    --equals "upload.headers.project-token=other-token" \
    --equals "finalize.headers.project-token=other-token"
}

token_not_printed() {
  run_upload TESTNOD_TOKEN=super-secret-token-value
  expect_status 0
  if grep -qF super-secret-token-value "$OUTPUT"; then
    echo "the token was printed in the output"
    return 1
  fi
}

finalize_false() {
  run_upload TESTNOD_FINALIZE=false TESTNOD_BUILD_ID=shard-build
  expect_status 0
  expect_requests \
    --count upload=1 --count presigned=1 --count finalize=0 \
    --equals "upload.body.test_run.metadata.build_id=shard-build"
}

finalize_only() {
  # No file and no download needed
  run_upload TESTNOD_FINALIZE=only TESTNOD_FILE= TESTNOD_BUILD_ID=shard-build TESTNOD_UPLOADER_VERSION=v0.0.0-does-not-exist
  expect_status 0
  expect_requests \
    --count upload=0 --count presigned=0 --count finalize=1 \
    --equals "finalize.body.build_id=shard-build"
}

tag_pipeline() {
  # CIRCLE_BRANCH is empty on tag-triggered pipelines
  run_upload CIRCLE_BRANCH= CIRCLE_TAG=v1.2.3
  expect_status 0
  expect_requests --count upload=1 --equals "upload.body.test_run.metadata.branch=v1.2.3"
}

missing_results_file() {
  run_upload TESTNOD_FILE=test/fixtures/does-not-exist.xml
  expect_status 0
  expect_output "not found"
  expect_requests --count upload=0 --count finalize=0
}

missing_file_parameter() {
  run_upload TESTNOD_FILE=
  expect_status 1
  expect_output "'file' parameter is required"
  expect_requests --count upload=0 --count finalize=0
}

missing_token() {
  run_upload TESTNOD_TOKEN=
  expect_status 1
  expect_output "'TESTNOD_TOKEN' is unset or empty"
  expect_requests --count upload=0 --count finalize=0
}

invalid_finalize() {
  run_upload TESTNOD_FINALIZE=sometimes
  expect_status 1
  expect_output "Invalid 'finalize' value"
  expect_requests --count upload=0 --count finalize=0
}

server_error() {
  fail_mock 500
  run_upload
  if [ "$STATUS" = 0 ]; then
    echo "expected a non-zero exit status"
    return 1
  fi
  # Stops after the failed upload, before finalize
  expect_requests --at-least upload=1 --count finalize=0
}

server_error_ignore_failures() {
  fail_mock 500
  run_upload TESTNOD_IGNORE_FAILURES=true
  expect_status 0
  expect_requests --at-least upload=1 --at-least finalize=1
}

server_error_ignore_failures_as_1() {
  # How a `true` boolean parameter can reach the script
  fail_mock 500
  run_upload TESTNOD_IGNORE_FAILURES=1
  expect_status 0
  expect_requests --at-least upload=1 --at-least finalize=1
}

finalize_error() {
  fail_mock 422
  run_upload TESTNOD_FINALIZE=only
  expect_status 1
  expect_output "Finalize returned HTTP 422"
  expect_requests --count finalize=1
}

unreachable_server() {
  run_upload TESTNOD_FINALIZE=only TESTNOD_BASE_URL=http://127.0.0.1:9
  expect_status 1
  expect_output "Finalize returned HTTP 000"
}

unreachable_server_ignore_failures() {
  run_upload TESTNOD_FINALIZE=only TESTNOD_BASE_URL=http://127.0.0.1:9 TESTNOD_IGNORE_FAILURES=true
  expect_status 0
}

missing_version() {
  rm -rf "$UPLOADER_DIR"
  run_upload TESTNOD_UPLOADER_VERSION=v0.0.0-does-not-exist
  if [ "$STATUS" = 0 ]; then
    echo "expected a non-zero exit status"
    return 1
  fi
  expect_requests --count upload=0 --count finalize=0
  if [ -e "${UPLOADER_DIR}/$(binary_name)" ]; then
    echo "expected no uploader binary to be left behind for save_cache"
    return 1
  fi
}

latest_version() {
  rm -rf "$UPLOADER_DIR"
  run_upload TESTNOD_UPLOADER_VERSION=latest
  expect_status 0
  expect_output "/latest/"
  expect_requests --count upload=1 --count presigned=1 --count finalize=1
}

binary_name() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
  esac
  echo "testnod-uploader-${os}-${arch}"
}

scenario "upload and finalize" upload_and_finalize
scenario "cached pinned binary" cached_binary
scenario "custom token variable name" custom_token_name
scenario "token isn't printed" token_not_printed
scenario "finalize false" finalize_false
scenario "finalize only" finalize_only
scenario "tag-triggered pipeline" tag_pipeline
scenario "missing results file" missing_results_file
scenario "missing file parameter" missing_file_parameter
scenario "missing token" missing_token
scenario "invalid finalize value" invalid_finalize
scenario "server error" server_error
scenario "server error with ignore_failures" server_error_ignore_failures
scenario "server error with ignore_failures as 1" server_error_ignore_failures_as_1
scenario "finalize error" finalize_error
scenario "unreachable server" unreachable_server
scenario "unreachable server with ignore_failures" unreachable_server_ignore_failures
scenario "version that doesn't exist" missing_version
scenario "latest version" latest_version

echo
echo "${PASSED} passed, ${#FAILED[@]} failed"
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
