"""Loopback-only fixtures for RangeFileDownload; no remote network required."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import time

DATA = bytes(i % 251 for i in range(100_003))
COUNTS = {}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/stats":
            payload = json.dumps(COUNTS.copy()).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if not match:
            self.send_error(400)
            return
        start, end = map(int, match.groups())
        key = f"{self.path}:{start}"
        COUNTS[key] = COUNTS.get(key, 0) + 1
        if self.path == "/transient" and start == 16_384 and COUNTS[key] == 1:
            self.send_error(503)
            return
        if self.path == "/subrange-transient" and start == 38_384 and COUNTS[key] == 1:
            self.send_error(503)
            return
        if self.path == "/slowcancel" and start == 16_384 and COUNTS[key] == 1:
            part = DATA[start:end + 1]
            self.send_response(206)
            self.send_header("ETag", '"fixture-v1"')
            self.send_header("Content-Length", str(len(part)))
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(DATA)}")
            self.end_headers()
            sent = 0
            try:
                while sent < len(part):
                    block = part[sent:sent + 256]
                    self.wfile.write(block)
                    sent += len(block)
                    COUNTS["slowcancel.bytes_sent"] = sent
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass
            COUNTS["slowcancel.done"] = 1
            return
        if self.path == "/ignored-large":
            # Deliberately violate Range. Count every successful socket write;
            # the Swift delegate should cancel on 200 before the full 64 MiB.
            size = 64 * 1024 * 1024
            self.send_response(200)
            self.send_header("ETag", '"fixture-v1"')
            self.send_header("Content-Length", str(size))
            self.end_headers()
            sent = 0
            block = bytes(16 * 1024)
            try:
                while sent < size:
                    self.wfile.write(block)
                    sent += len(block)
                    time.sleep(0.001)
            except (BrokenPipeError, ConnectionResetError):
                pass
            COUNTS["ignored-large.bytes_sent"] = sent
            return
        status = 200 if self.path == "/ignored" else 206
        part = DATA[start:end + 1]
        if self.path == "/short":
            part = part[:-1]
        self.send_response(status)
        self.send_header("ETag", '"changed"' if self.path == "/changed" else '"fixture-v1"')
        self.send_header("Content-Length", str(len(part)))
        if status == 206:
            total = len(DATA) + (1 if self.path == "/malformed" else 0)
            shown_start = start + (1 if self.path == "/wrong-start" else 0)
            self.send_header("Content-Range", f"bytes {shown_start}-{end}/{total}")
        self.end_headers()
        self.wfile.write(part)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18_473), Handler).serve_forever()
