"""Simulated PostgreSQL server for orders: checks client passwords against the mounted Secret."""

import os
import random
import signal
import socketserver
import sys
import threading
import time
from datetime import UTC, datetime
from pathlib import Path

CREDENTIALS = Path(os.environ.get("CREDENTIALS_DIR", "/etc/orders-db/credentials"))
HBA = 'Connection matched file "/var/lib/pgsql/data/pg_hba.conf" line 5: "host all all 0.0.0.0/0 scram-sha-256"'


def log(level, message, pid=None):
    ts = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print(f"{ts} UTC [{pid or os.getpid()}] {level}:  {message}", flush=True)


def credential(name):
    return (CREDENTIALS / name).read_text().strip()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        pid = random.randint(1000, 65000)
        fields = dict(f.split("=", 1) for f in self.rfile.readline().decode().split() if "=" in f)
        if not fields:  # TCP probe
            return
        user = fields.get("user", "")
        if user == credential("username") and fields.get("password") == credential("password"):
            self.wfile.write(b"OK\n")
            return
        log("FATAL", f'password authentication failed for user "{user}"', pid)
        log("DETAIL", HBA, pid)
        self.wfile.write(f'FATAL:  password authentication failed for user "{user}"\n'.encode())


def checkpoints():
    while True:
        time.sleep(300)
        buffers = random.randint(20, 400)
        log("LOG", "checkpoint starting: time")
        log("LOG", f"checkpoint complete: wrote {buffers} buffers ({buffers / 163.84:.1f}%); "
                   f"write={random.uniform(1, 30):.3f} s, sync={random.uniform(0, 0.05):.3f} s")


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log("LOG", "starting PostgreSQL 16.4 on x86_64-redhat-linux-gnu, compiled by gcc 11.5.0, 64-bit")
    log("LOG", 'listening on IPv4 address "0.0.0.0", port 5432')
    log("LOG", "database system was shut down at " + datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S UTC"))
    rotated = CREDENTIALS / "rotated-at"
    if rotated.exists():
        log("LOG", f'password for role "{credential("username")}" set from orders-db-credentials '
                   f"(rotated-at {rotated.read_text().strip()})")
    log("LOG", "database system is ready to accept connections")
    threading.Thread(target=checkpoints, daemon=True).start()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", 5432), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
