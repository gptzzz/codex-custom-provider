#!/usr/bin/env python3
"""A tiny local stand-in for an OpenAI-compatible gateway, used by test_doctor.py.

It listens on 127.0.0.1 only and never contacts the network, so the --live
checks of codex-doctor can be tested without a real key or a billed request.

    python3 tests/mock_gateway.py MODE      # prints the port on the first line

MODE:
    ok             GET /v1/models + streamed POST /v1/responses ending in response.completed
    no-completed   the stream stops before response.completed
    json-not-sse   POST /v1/responses ignores stream=true and returns plain JSON
    no-responses   POST /v1/responses returns 404 (a Chat-Completions-only gateway)
    failed         the stream ends with response.failed

The expected key is read from MOCK_GATEWAY_KEY (default "mock-key"). A wrong key
gets 401 {"code": "INVALID_API_KEY", "message": ...}.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "ok"
KEY = os.environ.get("MOCK_GATEWAY_KEY", "mock-key")
MODELS = ["test-model", "test-model-mini"]


def sse(event):
    return ("event: %s\ndata: %s\n\n" % (event["type"], json.dumps(event))).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep test output quiet
        pass

    def _send(self, status, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        if self.headers.get("Authorization") == "Bearer " + KEY:
            return True
        self._send(401, {"code": "INVALID_API_KEY", "message": "Invalid API key"})
        return False

    def do_GET(self):
        if self.path.rstrip("/") != "/v1/models":
            self._send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
            return
        if self._authorized():
            self._send(200, {"object": "list", "data": [{"id": m, "object": "model"} for m in MODELS]})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path.rstrip("/") != "/v1/responses" or MODE == "no-responses":
            self._send(404, {"error": {"message": "Invalid URL (POST %s)" % self.path, "type": "invalid_request_error"}})
            return
        if not self._authorized():
            return
        if body.get("model") not in MODELS:
            self._send(400, {"error": {"message": "model_not_found: %s" % body.get("model"), "type": "invalid_request_error"}})
            return
        response = {"id": "resp_mock_1", "object": "response", "status": "completed", "model": body["model"],
                    "output": [{"type": "message", "role": "assistant",
                                "content": [{"type": "output_text", "text": "pong"}]}],
                    "usage": {"input_tokens": 12, "output_tokens": 2, "total_tokens": 14}}
        if MODE == "json-not-sse":
            self._send(200, response)
            return
        events = [
            {"type": "response.created", "response": dict(response, status="in_progress", usage=None)},
            {"type": "response.output_text.delta", "delta": "pong", "output_index": 0, "content_index": 0},
        ]
        if MODE == "ok":
            events.append({"type": "response.completed", "response": response})
        elif MODE == "failed":
            events.append({"type": "response.failed", "response": dict(
                response, status="failed", error={"code": "server_error", "message": "upstream failed"})})
        payload = b"".join(sse(e) for e in events)
        self._send(200, payload, "text/event-stream")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
