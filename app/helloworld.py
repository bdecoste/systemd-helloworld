#!/usr/bin/env python3
"""
HelloWorld HTTP service.

Config is read from environment variables. Logs go to stdout.
These two properties are what let the SAME binary run under systemd
on a VM or as a container in Kubernetes, unmodified.
"""

import json
import logging
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
GREETING = os.environ.get("GREETING", "Hello, World!")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("helloworld")


class Handler(BaseHTTPRequestHandler):
    def _respond(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            self._respond(200, {"status": "ok"})
        elif self.path == "/":
            self._respond(200, {
                "message": GREETING,
                "environment": ENVIRONMENT,
                "host": os.uname().nodename,
            })
        else:
            self._respond(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


def shutdown(server):
    # server.shutdown() blocks until serve_forever() returns, so it must
    # run on a different thread than the one calling serve_forever().
    def handler(signum, _frame):
        log.info("received signal %d, shutting down", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()
    return handler


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    signal.signal(signal.SIGTERM, shutdown(server))
    signal.signal(signal.SIGINT, shutdown(server))
    log.info("listening on 0.0.0.0:%d environment=%s", PORT, ENVIRONMENT)
    server.serve_forever()
    log.info("stopped")


if __name__ == "__main__":
    main()
