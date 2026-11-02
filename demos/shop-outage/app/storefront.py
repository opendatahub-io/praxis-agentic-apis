"""Simulated web frontend: serves pages and generates shopper traffic, proxying checkout to checkout-api."""

import os
import random
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHECKOUT_URL = os.environ["CHECKOUT_API_URL"]
PAGES = ["/", "/", "/products/sku-1042", "/products/sku-2210", "/products/sku-3381", "/search?q=boots", "/cart"]
AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) Safari/605.1",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) Firefox/144.0",
]
stats = Counter()
lock = threading.Lock()


def log(line):
    print(line, flush=True)


def access(method, path, status, rt, upstream=None):
    ts = datetime.now(UTC).strftime("%d/%b/%Y:%H:%M:%S +0000")
    ip = f"10.{random.randint(128, 131)}.{random.randint(0, 9)}.{random.randint(2, 250)}"
    line = f'{ip} - - [{ts}] "{method} {path} HTTP/1.1" {status} "{random.choice(AGENTS)}" rt={rt:.3f}'
    if upstream:
        line += f" {upstream}"
    log(line)
    with lock:
        stats["total"] += 1
        stats[f"{status // 100}xx"] += 1
        if path == "/checkout":
            stats["checkout"] += 1
            stats["checkout_5xx"] += status >= 500


def checkout():
    start = time.monotonic()
    request = urllib.request.Request(CHECKOUT_URL, data=b'{"cart_id":"c1"}', method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            status, upstream = 303, f"upstream_status={response.status}"
    except urllib.error.HTTPError as error:
        status, upstream = 502, f"upstream_status={error.code}"
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        status, upstream = 502, f'upstream_status=- error="{reason}"'
    access("POST", "/checkout", status, time.monotonic() - start, f"upstream=checkout-api:8080 {upstream}")


def traffic():
    while True:
        time.sleep(random.uniform(0.5, 2.5))
        if random.random() < 0.25:
            checkout()
        else:
            access("GET", random.choice(PAGES), 200, random.uniform(0.004, 0.09))


def report():
    while True:
        time.sleep(60)
        with lock:
            s = dict(stats)
            stats.clear()
        level = "WARN" if s.get("5xx") else "INFO"
        log(f"{datetime.now(UTC).isoformat(timespec='seconds')} {level} stats last 60s: "
            f"requests={s.get('total', 0)} 2xx={s.get('2xx', 0)} 3xx={s.get('3xx', 0)} 5xx={s.get('5xx', 0)} "
            f"checkout={s.get('checkout', 0)} checkout_5xx={s.get('checkout_5xx', 0)}")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"ok" if self.path == "/healthz" else b"<html><body><h1>Shop</h1></body></html>"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"{datetime.now(UTC).isoformat(timespec='seconds')} INFO storefront "
        f"v{os.environ.get('APP_VERSION', 'dev')} listening on 0.0.0.0:8080, checkout upstream {CHECKOUT_URL}")
    threading.Thread(target=traffic, daemon=True).start()
    threading.Thread(target=report, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()


if __name__ == "__main__":
    main()
