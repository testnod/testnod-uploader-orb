"""Asserts on the requests recorded by test/mock_server.py.

  --count ENDPOINT=N      exactly N requests hit ENDPOINT
                          (upload, presigned, finalize, upload_failed)
  --at-least ENDPOINT=N   at least N requests hit ENDPOINT (for retried requests)
  --equals PATH=VALUE     a field of the last request to an endpoint equals VALUE.
                          PATH is ENDPOINT.body.<keys...> or ENDPOINT.headers.<name>;
                          VALUE is compared as text against string fields, and parsed
                          as JSON for anything else (lists, objects, numbers).
  --body-file ENDPOINT=F  the last request body to ENDPOINT equals the contents of F

Example:
  python test/expect.py --count upload=1 --equals upload.body.test_run.metadata.build_id=42
"""

import argparse
import json
import sys
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--url", default="http://127.0.0.1:8765")
parser.add_argument("--count", action="append", default=[])
parser.add_argument("--at-least", action="append", default=[])
parser.add_argument("--equals", action="append", default=[])
parser.add_argument("--body-file", action="append", default=[])
args = parser.parse_args()

with urllib.request.urlopen(f"{args.url}/__requests") as resp:
    requests = json.load(resp)

failures = []


def last_request(endpoint):
    matching = [r for r in requests if r["endpoint"] == endpoint]
    if not matching:
        failures.append(f"no request recorded for '{endpoint}'")
        return None
    return matching[-1]


for spec in args.count:
    endpoint, expected = spec.split("=", 1)
    actual = sum(1 for r in requests if r["endpoint"] == endpoint)
    if actual != int(expected):
        failures.append(f"expected {expected} '{endpoint}' request(s), got {actual}")

for spec in args.at_least:
    endpoint, expected = spec.split("=", 1)
    actual = sum(1 for r in requests if r["endpoint"] == endpoint)
    if actual < int(expected):
        failures.append(f"expected at least {expected} '{endpoint}' request(s), got {actual}")

for spec in args.equals:
    path, raw = spec.split("=", 1)
    endpoint, *keys = path.split(".")
    value = last_request(endpoint)
    if value is None:
        continue
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            failures.append(f"'{path}' not found in the last '{endpoint}' request")
            break
        value = value[key]
    else:
        # Build IDs like "12345" must stay strings, so only parse VALUE as JSON
        # when the recorded field isn't a string
        expected = raw if isinstance(value, str) else json.loads(raw)
        if value != expected:
            failures.append(f"'{path}': expected {expected!r}, got {value!r}")

for spec in args.body_file:
    endpoint, file_path = spec.split("=", 1)
    request = last_request(endpoint)
    if request is None:
        continue
    # newline="" keeps CRLF intact, since checkout on Windows converts line endings
    with open(file_path, encoding="utf-8", newline="") as f:
        if request["body"] != f.read():
            failures.append(f"'{endpoint}' body does not match {file_path}")

if failures:
    print("Recorded requests:")
    print(json.dumps(requests, indent=2))
    for failure in failures:
        print(f"::error::{failure}")
    sys.exit(1)

print(f"OK ({len(requests)} request(s) recorded)")
