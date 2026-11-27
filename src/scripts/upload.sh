#!/usr/bin/env bash
#
# TestNod uploader — CircleCI orb command script.
#
# This is a pure, shellcheck-clean bash script. It receives all orb
# parameters through environment variables set by the command's `environment:`
# block (never via `<<parameters.x>>` interpolation), so it can be linted and
# run locally as ordinary bash. It uploads a JUnit XML report to TestNod and
# optionally finalizes the test run.
#
# SECURITY: never enable `set -x` / `set -o xtrace` in this script — xtrace
# would print the resolved TestNod token. The token is only ever passed to the
# uploader binary as an argument and to the finalize endpoint as an HTTP header;
# it is never echoed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Inputs (set by the command's `environment:` block):
#   TESTNOD_TOKEN_NAME        name of the env var holding the API token
#   TESTNOD_FILE              JUnit XML path (positional arg to the binary)
#   TESTNOD_TAGS              comma-separated tags
#   TESTNOD_IGNORE_FAILURES   "true" | "false"
#   TESTNOD_RETRY             "true" | "false"
#   TESTNOD_UPLOADER_VERSION  "latest" or a pinned version
#   TESTNOD_BUILD_ID          explicit build id, or "" to default to workflow id
#   TESTNOD_FINALIZE          "true" | "false" | "only"
#
# Optional ambient override:
#   TESTNOD_BASE_URL          finalize API base URL (default https://testnod.com)
#
# CircleCI built-ins consumed: CIRCLE_BRANCH, CIRCLE_TAG, CIRCLE_SHA1,
#   CIRCLE_BUILD_URL, CIRCLE_WORKFLOW_ID
# ---------------------------------------------------------------------------

# Check the test results file: if we intend to upload (finalize != only) and a
# file path was provided but does not exist, skip the ENTIRE upload + finalize
# and succeed. This handles the common case where a step before the tests failed
# and no report was produced.
if [ "$TESTNOD_FINALIZE" != "only" ] && [ -n "$TESTNOD_FILE" ]; then
  if [ ! -f "$TESTNOD_FILE" ]; then
    echo "WARNING: Test results file '${TESTNOD_FILE}' not found — skipping TestNod upload. This usually means a step before the tests failed."
    exit 0
  fi
fi

# Defensive validation of the finalize mode. The `finalize` parameter is an enum
# validated at config-compile time, so this is belt-and-suspenders. It runs
# AFTER the missing-file skip so a set-but-missing file never trips an error
# here.
case "$TESTNOD_FINALIZE" in
  true | false | only) ;;
  *)
    echo "ERROR: Invalid 'finalize' value: '${TESTNOD_FINALIZE}'. Must be 'true', 'false', or 'only'." >&2
    exit 1
    ;;
esac

# The compiled config turns "<<parameters.ignore_failures>>" and
# "<<parameters.retry>>" into YAML booleans, which can reach the script as "1"
# rather than "true".
case "$TESTNOD_IGNORE_FAILURES" in
  true | 1) TESTNOD_IGNORE_FAILURES=true ;;
  *) TESTNOD_IGNORE_FAILURES=false ;;
esac

case "${TESTNOD_RETRY:-false}" in
  true | 1) TESTNOD_RETRY=true ;;
  *) TESTNOD_RETRY=false ;;
esac

# Resolve the token from the named env var via bash indirect expansion. Only the
# variable NAME ever reaches the compiled config; the value is dereferenced here
# at runtime.
TESTNOD_TOKEN="${!TESTNOD_TOKEN_NAME:-}"
if [ -z "$TESTNOD_TOKEN" ]; then
  echo "ERROR: TestNod token environment variable '${TESTNOD_TOKEN_NAME}' is unset or empty." >&2
  echo "Set the token in a CircleCI context or project environment variable, then pass its NAME (not the value) via the 'token' parameter." >&2
  exit 1
fi

# Build id groups parallel containers / fan-out jobs into one logical run.
# Default to the workflow id, which is shared across a workflow's containers.
EFFECTIVE_BUILD_ID="${TESTNOD_BUILD_ID:-${CIRCLE_WORKFLOW_ID:-}}"

# CIRCLE_BRANCH is empty on tag-triggered pipelines; fall back to the tag.
BRANCH="${CIRCLE_BRANCH:-${CIRCLE_TAG:-}}"

UPLOAD_FAILED=false

# Fails the step, or with ignore_failures prints a warning and carries on.
fail_or_warn() {
  if [ "$TESTNOD_IGNORE_FAILURES" != "true" ]; then
    echo "ERROR: $1" >&2
    exit 1
  fi
  echo "WARNING: $1" >&2
}

# --------------------------- upload phase ----------------------------------
if [ "$TESTNOD_FINALIZE" != "only" ]; then
  if [ -z "$TESTNOD_FILE" ]; then
    echo "ERROR: the 'file' parameter is required unless finalize=only." >&2
    exit 1
  fi

  # Detect platform/arch and assemble the binary name.
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"

  case "$OS" in
    linux) PLATFORM="linux" ;;
    darwin) PLATFORM="darwin" ;;
    mingw* | msys* | cygwin*) PLATFORM="windows" ;;
    *)
      echo "ERROR: Unsupported OS: ${OS}" >&2
      exit 1
      ;;
  esac

  case "$ARCH" in
    x86_64 | amd64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    *)
      echo "ERROR: Unsupported architecture: ${ARCH}" >&2
      exit 1
      ;;
  esac

  EXTENSION=""
  if [ "$PLATFORM" = "windows" ]; then
    EXTENSION=".exe"
  fi

  BINARY_NAME="testnod-uploader-${PLATFORM}-${ARCH}${EXTENSION}"
  DEST_DIR="/tmp/testnod-uploader"
  BINARY_PATH="${DEST_DIR}/${BINARY_NAME}"
  mkdir -p "$DEST_DIR"

  # Download the uploader unless a PINNED version is already present on disk
  # (e.g. restored from cache). `latest` always re-downloads.
  if [ -f "$BINARY_PATH" ] && [ "$TESTNOD_UPLOADER_VERSION" != "latest" ]; then
    echo "Using cached TestNod uploader at ${BINARY_PATH}"
  else
    DOWNLOAD_URL="https://releases.testnod.com/testnod-uploader/${TESTNOD_UPLOADER_VERSION}/${BINARY_NAME}"
    echo "Downloading TestNod uploader from ${DOWNLOAD_URL}"
    curl -fsSL --retry 3 --retry-delay 5 -o "$BINARY_PATH" "$DOWNLOAD_URL"
  fi
  chmod +x "$BINARY_PATH"

  # Assemble the binary arguments. The token is passed as the -token= argument
  # (the binary's interface), so it is visible in /proc/PID/cmdline for the
  # binary's lifetime — acceptable because CircleCI jobs run in an isolated,
  # single-tenant container. It is never echoed or logged.
  ARGS=(
    -token="$TESTNOD_TOKEN"
    -branch="$BRANCH"
    -commit-sha="${CIRCLE_SHA1:-}"
    -run-url="${CIRCLE_BUILD_URL:-}"
    -build-id="$EFFECTIVE_BUILD_ID"
  )

  # Split comma-separated tags into individual -tag flags, trimming whitespace.
  if [ -n "$TESTNOD_TAGS" ]; then
    IFS=',' read -ra TAG_ARRAY <<< "$TESTNOD_TAGS"
    for tag in "${TAG_ARRAY[@]}"; do
      tag="$(echo "$tag" | xargs)" # trim leading/trailing whitespace
      if [ -n "$tag" ]; then
        ARGS+=(-tag="$tag")
      fi
    done
  fi

  # Marks this upload as a rerun; the uploader sends a top-level "retry": true.
  if [ "$TESTNOD_RETRY" = "true" ]; then
    ARGS+=(-retry)
  fi

  # The file path is the final positional argument.
  ARGS+=("$TESTNOD_FILE")

  # The uploader prints the reason for a failure, including TestNod's
  # error_message (for example, why a 403 refused the upload). ignore_failures
  # is handled here rather than with the uploader's -ignore-failures flag, so
  # the script still sees the exit status and finalize can tell why it has
  # nothing to finalize.
  echo "Running TestNod uploader..."
  set +e
  "$BINARY_PATH" "${ARGS[@]}"
  UPLOAD_STATUS=$?
  set -e

  if [ "$UPLOAD_STATUS" -ne 0 ]; then
    UPLOAD_FAILED=true
    fail_or_warn "The TestNod upload failed (uploader exit status ${UPLOAD_STATUS}). The reason is in the uploader's output above."
  fi
fi

# -------------------------- finalize phase ---------------------------------
if [ "$TESTNOD_FINALIZE" = "true" ] || [ "$TESTNOD_FINALIZE" = "only" ]; then
  BASE_URL="${TESTNOD_BASE_URL:-https://testnod.com}"
  echo "Finalizing TestNod test run for build ${EFFECTIVE_BUILD_ID}..."

  # `|| true` so a connection error doesn't exit under `set -e`: curl still
  # writes "000" as the status code, which is handled below. curl also retries
  # a 429; TestNod's rate limit is per minute, so wait 5 seconds between tries.
  HTTP_CODE="$(curl -sS -o /tmp/testnod-finalize.body -w "%{http_code}" \
    --retry 3 --retry-delay 5 --retry-connrefused \
    -X POST "${BASE_URL}/integrations/test_runs/finalize" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Project-Token: ${TESTNOD_TOKEN}" \
    -d "{\"build_id\":\"${EFFECTIVE_BUILD_ID}\"}")" || true

  if [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
    # curl got no response at all (DNS failure, connection refused, timeout)
    fail_or_warn "Finalize returned HTTP 000: no response from TestNod."
  elif [ "$HTTP_CODE" != "200" ]; then
    BODY="$(cat /tmp/testnod-finalize.body 2>/dev/null || true)"
    # TestNod errors look like {"error_message": "..."}; fall back to the raw body.
    MESSAGE="$(printf '%s' "$BODY" | sed -n 's/.*"error_message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    MESSAGE="${MESSAGE:-$BODY}"

    if [ "$HTTP_CODE" = "404" ] && [ "$UPLOAD_FAILED" = "true" ]; then
      # The upload failure was already reported; a second warning would bury it.
      echo "Nothing to finalize for build ${EFFECTIVE_BUILD_ID} because the upload above failed. TestNod said: ${MESSAGE}"
    elif [ "$HTTP_CODE" = "404" ] && [[ "$MESSAGE" == "Test run not found"* ]]; then
      fail_or_warn "Finalize returned HTTP 404: ${MESSAGE} No test run exists for build ${EFFECTIVE_BUILD_ID}. If the upload steps for this build failed, for example with a 403 because uploads are paused for the organization or project, the reason is in their logs."
    else
      fail_or_warn "Finalize returned HTTP ${HTTP_CODE}: ${MESSAGE}"
    fi
  else
    echo "Test run finalized."
  fi
fi
