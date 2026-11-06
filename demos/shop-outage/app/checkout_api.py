"""Simulated checkout API: authenticates to orders-db with credentials read from env at startup."""

import json
import os
import random
import signal
import socket
import sys
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("APP_VERSION", "dev")
DB_HOST = os.environ["DATABASE_HOST"]
DB_PORT = int(os.environ["DATABASE_PORT"])
DB_NAME = os.environ["DATABASE_NAME"]
DB_USER = os.environ["DATABASE_USER"]
DB_PASSWORD = os.environ["DATABASE_PASSWORD"]


def log(level, message):
    ts = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    print(f"{ts} {level:<5} {message}", flush=True)


def db_connect():
    """Return None on success, else a psycopg2-style error message."""
    try:
        addr = socket.gethostbyname(DB_HOST)
    except OSError:
        return f'could not translate host name "{DB_HOST}" to address: Name or service not known'
    prefix = f'connection to server at "{DB_HOST}" ({addr}), port {DB_PORT} failed: '
    try:
        with socket.create_connection((addr, DB_PORT), timeout=2) as sock:
            sock.sendall(f"user={DB_USER} database={DB_NAME} password={DB_PASSWORD}\n".encode())
            reply = sock.makefile().readline().strip()
    except OSError as error:
        return prefix + str(error)
    return None if reply == "OK" else prefix + reply


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz/live":
            self.reply(200, {"status": "ok"})
        elif self.path == "/healthz/ready":
            error = db_connect()
            self.reply(503 if error else 200, {"status": "unavailable" if error else "ok"})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/v1/checkout":
            self.reply(404, {"error": "not found"})
            return
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        start = time.monotonic()
        error = db_connect()
        ms = (time.monotonic() - start) * 1000 + random.uniform(15, 60)
        if error:
            log("ERROR", f"checkout.db: psycopg2.OperationalError: {error}")
            log("WARN", f"POST /api/v1/checkout 503 {ms:.0f}ms")
            self.reply(503, {"error": "database unavailable"})
        else:
            order = f"ord_{random.randint(10**9, 10**10 - 1)}"
            log("INFO", f"POST /api/v1/checkout 201 {ms:.0f}ms order={order}")
            self.reply(201, {"order_id": order})


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("INFO", f"checkout-api v{VERSION} starting")
    log("INFO", "loading config from environment")
    log("INFO", f"database postgresql://{DB_USER}@{DB_HOST}:{DB_PORT}/{DB_NAME}")
    error = db_connect()
    if error:
        log("ERROR", f"checkout.db: psycopg2.OperationalError: {error}")
    else:
        log("INFO", "database connection pool ready (size=10, recycle=60s)")
    log("INFO", "listening on 0.0.0.0:8080")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()


if __name__ == "__main__":
    main()
