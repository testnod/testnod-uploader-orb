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

  if [ "$TESTNOD_IGNORE_FAILURES" = "true" ]; then
    ARGS+=(-ignore-failures)
  fi

  # The file path is the final positional argument.
  ARGS+=("$TESTNOD_FILE")

  echo "Running TestNod uploader..."
  "$BINARY_PATH" "${ARGS[@]}"
fi

# -------------------------- finalize phase ---------------------------------
if [ "$TESTNOD_FINALIZE" = "true" ] || [ "$TESTNOD_FINALIZE" = "only" ]; then
  BASE_URL="${TESTNOD_BASE_URL:-https://testnod.com}"
  echo "Finalizing TestNod test run for build ${EFFECTIVE_BUILD_ID}..."

  HTTP_CODE="$(curl -sS -o /tmp/testnod-finalize.body -w "%{http_code}" \
    --retry 3 --retry-delay 2 --retry-connrefused \
    -X POST "${BASE_URL}/integrations/test_runs/finalize" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "Project-Token: ${TESTNOD_TOKEN}" \
    -d "{\"build_id\":\"${EFFECTIVE_BUILD_ID}\"}")"

  if [ "$HTTP_CODE" != "200" ]; then
    BODY="$(cat /tmp/testnod-finalize.body 2>/dev/null || true)"
    echo "WARNING: Finalize returned HTTP ${HTTP_CODE}: ${BODY}" >&2
    if [ "$TESTNOD_IGNORE_FAILURES" != "true" ]; then
      exit 1
    fi
  else
    echo "Test run finalized."
  fi
fi
