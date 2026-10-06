"""In-cluster mock LLM upstream for AI Gateway custom-host tests (lab only; unofficial, no support, MIT).

Runs in-cluster (stdlib only). Answers OpenAI POST .../chat/completions and Anthropic POST .../messages with a canned
reply whose text names the cell (env CELL) and the Host it was reached on, so a gateway response shows which address
the gateway actually dialled. Anything else gets a JSON 404 that also names the cell. Logs one JSON line per request to
stdout: cell, host, method, path, model, and header names with masked values.
"""

import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CELL = os.environ.get("CELL", "unknown")


def mask(v):
    return v if len(v) <= 12 else f"{v[:4]}…{v[-4:]} ({len(v)} chars)"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # replaced by the JSON line below
        pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        try:
            req = json.loads(raw) if raw else {}
        except ValueError:
            req = {}
        req = req if isinstance(req, dict) else {}
        host = self.headers.get("host", "")
        print(json.dumps({"mock": "request", "cell": CELL, "host": host, "method": self.command, "path": self.path,
                          "source_ip": self.client_address[0], "model": req.get("model"),
                          "headers": {k.lower(): mask(v) for k, v in sorted(self.headers.items())}}), flush=True)
        text = f"mock cell={CELL} host={host}"
        path = self.path.split("?")[0]
        if self.command == "POST" and path.endswith("/chat/completions"):
            return self.send(200, {"id": "chatcmpl-mock-" + uuid.uuid4().hex[:12], "object": "chat.completion",
                                   "created": int(time.time()), "model": req.get("model") or "mock",
                                   "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                                "finish_reason": "stop"}],
                                   "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}})
        if self.command == "POST" and path.endswith("/messages"):
            return self.send(200, {"id": "msg_mock_" + uuid.uuid4().hex[:12], "type": "message", "role": "assistant",
                                   "model": req.get("model") or "mock", "content": [{"type": "text", "text": text}],
                                   "stop_reason": "end_turn", "stop_sequence": None,
                                   "usage": {"input_tokens": 10, "output_tokens": 1}})
        self.send(404, {"error": {"message": f"{text} path={path}", "type": "not_found"}})

    do_GET = do_POST = handle_any


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
