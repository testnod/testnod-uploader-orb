"""Fake TestNod API for testing the orb without touching testnod.com.

Implements the endpoints the uploader binary and the orb's finalize step
call, and records every request so test steps can assert on them.

Control endpoints (not part of the TestNod API):
  GET    /__requests  recorded requests as JSON
  DELETE /__requests  clear recorded requests and every failure rule
  POST   /__fail      add a failure rule until the next reset. Body:
                        status    HTTP status to answer with (required)
                        endpoint  only fail this endpoint (upload, presigned,
                                  finalize, upload_failed); default: all
                        body      JSON response body;
                                  default: {"error_message": "simulated failure"}
                        times     fail this many requests, then stop; default: all
                      The first rule that matches a request answers it.

Usage: python test/mock_server.py [--port 8765]
"""

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPLOAD_PATH = "/integrations/test_runs/upload"
UPLOAD_FAILED_PATH = "/integrations/test_runs/upload_failed"
FINALIZE_PATH = "/integrations/test_runs/finalize"
PRESIGNED_PATH = "/presigned/upload"

state = {"requests": [], "failures": []}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/__requests":
            self.respond(200, state["requests"])
        else:
            self.respond(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/__requests":
            with lock:
                state["requests"].clear()
                state["failures"].clear()
            self.respond(200, {})
        else:
            self.respond(404, {"error": "not found"})

    def do_POST(self):
        body = self.read_body()

        if self.path == "/__fail":
            rule = json.loads(body)
            with lock:
                state["failures"].append({
                    "status": rule["status"],
                    "endpoint": rule.get("endpoint"),
                    "body": rule.get("body", {"error_message": "simulated failure"}),
                    "times": rule.get("times"),
                })
            self.respond(200, {})
            return

        endpoint = {
            UPLOAD_PATH: "upload",
            UPLOAD_FAILED_PATH: "upload_failed",
            FINALIZE_PATH: "finalize",
        }.get(self.path)
        if endpoint is None:
            self.respond(404, {"error": "not found"})
            return

        self.record(endpoint, json.loads(body))
        if self.fail_if_requested(endpoint):
            return

        if endpoint == "upload":
            host = self.headers["Host"]
            self.respond(201, {
                "id": 1,
                "project_id": "00000000-0000-4000-8000-000000000001",
                "test_run_id": 1,
                "upload_id": 1,
                "test_run_url": f"http://{host}/test_runs/1",
                "presigned_url": f"http://{host}{PRESIGNED_PATH}",
            })
        else:
            self.respond(200, {})

    def do_PUT(self):
        body = self.read_body()
        if self.path != PRESIGNED_PATH:
            self.respond(404, {"error": "not found"})
            return

        self.record("presigned", body.decode("utf-8"))
        if self.fail_if_requested("presigned"):
            return
        self.respond(200, {})

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length)

    def record(self, endpoint, body):
        with lock:
            state["requests"].append({
                "endpoint": endpoint,
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body,
            })

    def fail_if_requested(self, endpoint):
        with lock:
            rule = next((r for r in state["failures"]
                         if r["endpoint"] in (None, endpoint) and r["times"] != 0), None)
            if rule is None:
                return False
            if rule["times"] is not None:
                rule["times"] -= 1
        self.respond(rule["status"], rule["body"])
        return True

    def respond(self, status, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Mock TestNod listening on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()
