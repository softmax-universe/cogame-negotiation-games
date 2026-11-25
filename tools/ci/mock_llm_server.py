#!/usr/bin/env python3
"""Deterministic local HTTP Anthropic Messages fixture for credential-free CI only.

NEVER put this server's URL in coworld_manifest_template.json or any published
manifest. It exists solely so credential-free CI smoke and local `coworld
certify` can exercise the real HTTP model-player path without provider secrets.
"""
from __future__ import annotations

import argparse
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POOL_RE = re.compile(r"THE POOL:\s*(\d+)\s+books?,\s*(\d+)\s+hats?,\s*(\d+)\s+balls?")
ACCEPT_RE = re.compile(r"ACCEPT IS LEGAL NOW:\s*(yes|no)", re.IGNORECASE)


def decide_action(user_text: str) -> dict:
    accept_match = ACCEPT_RE.search(user_text)
    if accept_match and accept_match.group(1).lower() == "yes":
        return {
            "action": "accept",
            "message": "Agreed, let us close this deal.",
            "notes": "accepted standing offer",
        }
    pool_match = POOL_RE.search(user_text)
    if pool_match:
        books, hats, balls = (int(pool_match.group(i)) for i in (1, 2, 3))
        take = {
            "books": (books + 1) // 2,
            "hats": hats // 2,
            "balls": balls // 2,
        }
    else:
        take = {"books": 0, "hats": 0, "balls": 0}
    return {
        "action": "offer",
        "take": take,
        "message": "Opening with a balanced split.",
        "notes": "proposed split",
    }


class MockAnthropicHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/healthz":
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if self.path != "/v1/messages":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        payload = json.loads(raw.decode("utf-8"))
        model = payload.get("model") or "anthropic/claude-haiku-4.5"
        messages = payload.get("messages") or []
        user_text = ""
        for msg in messages:
            if isinstance(msg, dict) and msg.get("role") == "user":
                content = msg.get("content", "")
                if isinstance(content, str):
                    user_text += content + "\n"
        action_json = json.dumps(decide_action(user_text))
        response = {
            "id": "msg_ci_fixture",
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [{"type": "text", "text": action_json}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 64, "output_tokens": 24},
        }
        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18089)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), MockAnthropicHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
