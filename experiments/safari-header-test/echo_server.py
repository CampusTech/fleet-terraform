#!/usr/bin/env python3
"""Echo server: reflects every received request header back as JSON and logs to stdout.

Authoritative view of the exact header name is the ngrok inspector at
http://127.0.0.1:4040 (Python title-cases header names). This is the backup view.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

PORT = 8080  # ngrok http 8080 --url campussafari.ngrok.dev


class EchoHandler(BaseHTTPRequestHandler):
    def _echo(self):
        # raw header lines, before dict normalization, to preserve casing as best we can
        raw = self.headers.as_string()
        headers = dict(self.headers.items())
        print("=" * 60)
        print(f"{self.command} {self.path}")
        print("--- raw header block ---")
        print(raw)
        print("--- looking for GoogApps header ---")
        for k in headers:
            if "googapps" in k.lower() or "safari-extension" in k.lower():
                print(f"  FOUND: {k!r}: {headers[k]!r}")
        body = json.dumps({"raw": raw, "headers": headers}, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _echo
    do_POST = _echo


if __name__ == "__main__":
    print(f"Echo server on http://127.0.0.1:{PORT} — Ctrl-C to stop")
    HTTPServer(("127.0.0.1", PORT), EchoHandler).serve_forever()
