#!/usr/bin/env python3
"""Test-only loopback proxy. Refuses every remote request; records no credentials."""
import argparse
import http.server
import json
import pathlib
import threading

parser = argparse.ArgumentParser()
parser.add_argument("--port-file", required=True)
args = parser.parse_args()
records = []
lock = threading.Lock()

class Recorder(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_CONNECT(self):
        with lock:
            records.append(f"CONNECT {self.path}")
        self.send_error(403, "Test proxy refuses remote traffic")

    def do_GET(self):
        if self.path == "/records":
            with lock:
                data = json.dumps(records).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            with lock:
                records.append(f"GET {self.path}")
            self.send_error(403, "Test proxy refuses remote traffic")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
pathlib.Path(args.port_file).write_text(str(server.server_port))
server.serve_forever()
