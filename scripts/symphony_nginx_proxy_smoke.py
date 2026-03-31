#!/usr/bin/env python3

import argparse
import base64
import hashlib
import http.client
import json
import os
import pathlib
import re
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG_PATH = REPO_ROOT / "elixir" / "deploy" / "nginx" / "stream.cash.symphony-proxy.conf"
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


REQUIRED_PATTERNS = {
    "redirect": r"location\s+=\s+/proxy/symphony\s*\{\s*return\s+301\s+/proxy/symphony/;",
    "http_location": r"location\s+/proxy/symphony/\s*\{",
    "http_proxy_pass": r"proxy_pass\s+http://127\.0\.0\.1:4101/;",
    "live_location": r"location\s+/proxy/symphony/live/\s*\{",
    "live_proxy_pass": r"proxy_pass\s+http://127\.0\.0\.1:4101/live/;",
    "proxy_http_version": r"proxy_http_version\s+1\.1;",
    "upgrade_header": r"proxy_set_header\s+Upgrade\s+\$http_upgrade;",
    "connection_header": r'proxy_set_header\s+Connection\s+"upgrade";',
    "forwarded_host": r"proxy_set_header\s+X-Forwarded-Host\s+\$host;",
    "forwarded_proto": r"proxy_set_header\s+X-Forwarded-Proto\s+\$scheme;",
    "forwarded_port": r"proxy_set_header\s+X-Forwarded-Port\s+\$server_port;",
    "forwarded_for": r"proxy_set_header\s+X-Forwarded-For\s+\$proxy_add_x_forwarded_for;",
}


def log(message):
    print(message, flush=True)


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def read_exact(sock, size):
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("unexpected EOF while reading websocket frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def build_text_frame(payload, masked):
    data = payload.encode("utf-8")
    first = bytes([0x81])
    mask_bit = 0x80 if masked else 0
    length = len(data)

    if length < 126:
        header = bytes([mask_bit | length])
    elif length < 65536:
        header = bytes([mask_bit | 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([mask_bit | 127]) + length.to_bytes(8, "big")

    if not masked:
        return first + header + data

    mask_key = os.urandom(4)
    masked_data = bytes(byte ^ mask_key[index % 4] for index, byte in enumerate(data))
    return first + header + mask_key + masked_data


def read_text_frame(sock):
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F

    if length == 126:
        length = int.from_bytes(read_exact(sock, 2), "big")
    elif length == 127:
        length = int.from_bytes(read_exact(sock, 8), "big")

    mask_key = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length)

    if masked:
        payload = bytes(byte ^ mask_key[index % 4] for index, byte in enumerate(payload))

    if opcode != 0x1:
        raise RuntimeError(f"expected text frame, got opcode {opcode}")

    return payload.decode("utf-8")


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ProxyUpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string, *args):
        log(f"upstream: {format_string % args}")

    def do_GET(self):
        if self.path.startswith("/live/"):
            self.handle_websocket()
            return

        body = json.dumps(
            {
                "path": self.path,
                "headers": {
                    "host": self.headers.get("Host"),
                    "x_forwarded_host": self.headers.get("X-Forwarded-Host"),
                    "x_forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                    "x_forwarded_port": self.headers.get("X-Forwarded-Port"),
                    "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                },
            }
        ).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_websocket(self):
        if self.path != "/live/echo":
            self.send_error(404)
            return

        if self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(400, "missing websocket upgrade")
            return

        client_key = self.headers.get("Sec-WebSocket-Key")
        if not client_key:
            self.send_error(400, "missing Sec-WebSocket-Key")
            return

        accept = base64.b64encode(
            hashlib.sha1(f"{client_key}{WEBSOCKET_GUID}".encode("utf-8")).digest()
        ).decode("ascii")

        self.send_response_only(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()

        message = read_text_frame(self.connection)
        response = f"{self.path}|{message}"
        self.connection.sendall(build_text_frame(response, masked=False))


class ManagedProcess:
    def __init__(self, argv, cwd):
        self.argv = argv
        self.cwd = cwd
        self.process = None

    def __enter__(self):
        self.process = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return self.process

    def __exit__(self, exc_type, exc, traceback):
        if self.process is None:
            return

        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

        output = self.process.stdout.read() if self.process.stdout else ""
        if output.strip():
            log("--- nginx output ---")
            log(output.rstrip())


def validate_contract():
    text = CONFIG_PATH.read_text(encoding="utf-8")
    missing = [name for name, pattern in REQUIRED_PATTERNS.items() if re.search(pattern, text, re.S) is None]

    if missing:
        raise RuntimeError(f"nginx contract is missing required directives: {', '.join(missing)}")

    log(f"contract ok: {CONFIG_PATH}")


def find_or_download_nginx(workdir):
    override = os.environ.get("NGINX_BIN")
    if override:
        nginx_bin = pathlib.Path(override)
        if nginx_bin.is_file() and os.access(nginx_bin, os.X_OK):
            return nginx_bin
        raise RuntimeError(f"NGINX_BIN is not executable: {override}")

    local_nginx = shutil.which("nginx")
    if local_nginx:
        return pathlib.Path(local_nginx)

    download_dir = pathlib.Path(workdir) / "apt-downloads"
    root_dir = pathlib.Path(workdir) / "nginx-root"
    download_dir.mkdir(parents=True, exist_ok=True)
    root_dir.mkdir(parents=True, exist_ok=True)

    log("nginx not found on PATH; downloading temporary Debian packages into the workspace")
    subprocess.run(
        ["apt-get", "download", "nginx", "nginx-common"],
        cwd=download_dir,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    for deb in download_dir.glob("*.deb"):
        subprocess.run(
            ["dpkg-deb", "-x", str(deb), str(root_dir)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    nginx_bin = root_dir / "usr" / "sbin" / "nginx"
    if not nginx_bin.is_file():
        raise RuntimeError("failed to extract a temporary nginx binary")

    return nginx_bin


def write_nginx_config(path, listen_port):
    client_body_temp = path.parent / "client_body_temp"
    proxy_temp = path.parent / "proxy_temp"
    fastcgi_temp = path.parent / "fastcgi_temp"
    uwsgi_temp = path.parent / "uwsgi_temp"
    scgi_temp = path.parent / "scgi_temp"

    for temp_dir in [client_body_temp, proxy_temp, fastcgi_temp, uwsgi_temp, scgi_temp]:
        temp_dir.mkdir(parents=True, exist_ok=True)

    path.write_text(
        "\n".join(
            [
                "worker_processes 1;",
                f"pid {path.parent / 'nginx.pid'};",
                f"error_log {path.parent / 'error.log'} info;",
                "events { worker_connections 128; }",
                "http {",
                "    access_log off;",
                f"    client_body_temp_path {client_body_temp};",
                f"    proxy_temp_path {proxy_temp};",
                f"    fastcgi_temp_path {fastcgi_temp};",
                f"    uwsgi_temp_path {uwsgi_temp};",
                f"    scgi_temp_path {scgi_temp};",
                "    server {",
                f"        listen 127.0.0.1:{listen_port};",
                "        server_name stream.cash;",
                f"        include {CONFIG_PATH};",
                "    }",
                "}",
                "",
            ]
        ),
        encoding="utf-8",
    )


def wait_for_http(port, path):
    deadline = time.time() + 10
    last_error = None

    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            conn.request("GET", path, headers={"Host": "stream.cash"})
            response = conn.getresponse()
            response.read()
            conn.close()
            return
        except OSError as error:
            last_error = error
            time.sleep(0.1)

    raise RuntimeError(f"nginx did not become ready in time: {last_error}")


def assert_redirect(port):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/proxy/symphony", headers={"Host": "stream.cash"})
    response = conn.getresponse()
    response.read()
    conn.close()

    location = response.getheader("Location")
    absolute_redirect = re.fullmatch(r"http://stream\.cash(?::\d+)?/proxy/symphony/", location or "")

    if response.status != 301 or (location != "/proxy/symphony/" and absolute_redirect is None):
        raise RuntimeError(
            f"expected /proxy/symphony redirect, got status={response.status} location={location}"
        )

    log("redirect ok: /proxy/symphony -> /proxy/symphony/")


def assert_http_proxy(port):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/proxy/symphony/", headers={"Host": "stream.cash"})
    response = conn.getresponse()
    body = response.read()
    conn.close()

    if response.status != 200:
        raise RuntimeError(f"expected proxied dashboard response, got status={response.status}")

    payload = json.loads(body.decode("utf-8"))

    if payload["path"] != "/":
        raise RuntimeError(f"expected upstream path '/', got {payload['path']}")

    headers = payload["headers"]
    if headers["host"] != "stream.cash":
        raise RuntimeError(f"expected Host=stream.cash, got {headers['host']}")

    if headers["x_forwarded_host"] != "stream.cash":
        raise RuntimeError(f"expected X-Forwarded-Host=stream.cash, got {headers['x_forwarded_host']}")

    if headers["x_forwarded_proto"] != "http":
        raise RuntimeError(f"expected X-Forwarded-Proto=http, got {headers['x_forwarded_proto']}")

    if not headers["x_forwarded_for"]:
        raise RuntimeError("expected X-Forwarded-For to be populated")

    log("http proxy ok: /proxy/symphony/ rewrites to upstream / with forwarded headers")


def assert_websocket_proxy(port):
    websocket_key = base64.b64encode(os.urandom(16)).decode("ascii")

    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        request = "\r\n".join(
            [
                "GET /proxy/symphony/live/echo HTTP/1.1",
                "Host: stream.cash",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {websocket_key}",
                "Sec-WebSocket-Version: 13",
                "",
                "",
            ]
        )
        sock.sendall(request.encode("ascii"))

        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)

        header_block = response.split(b"\r\n\r\n", 1)[0].decode("ascii")
        if "101 Switching Protocols" not in header_block:
            raise RuntimeError(f"expected websocket 101, got:\n{header_block}")

        sock.sendall(build_text_frame("live-ping", masked=True))
        payload = read_text_frame(sock)

    if payload != "/live/echo|live-ping":
        raise RuntimeError(f"unexpected websocket echo payload: {payload}")

    log("websocket proxy ok: /proxy/symphony/live/echo upgrades and reaches upstream /live/echo")


def detect_existing_symphony():
    try:
        with urllib.request.urlopen("http://127.0.0.1:4101/", timeout=5) as response:
            body = response.read(2048).decode("utf-8", "replace")
    except urllib.error.URLError:
        return False

    return "Symphony Observability" in body and "/proxy/symphony/" in body


def assert_existing_symphony_http_proxy(port):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/proxy/symphony/", headers={"Host": "stream.cash"})
    response = conn.getresponse()
    body = response.read().decode("utf-8", "replace")
    conn.close()

    if response.status != 200:
        raise RuntimeError(f"expected proxied dashboard response, got status={response.status}")

    required_fragments = [
        "Symphony Observability",
        "/proxy/symphony/dashboard.css",
        'LiveSocket("/proxy/symphony/live"',
    ]

    missing = [fragment for fragment in required_fragments if fragment not in body]
    if missing:
        raise RuntimeError(f"proxied dashboard HTML is missing expected fragments: {missing}")

    log("http proxy ok: proxied Symphony dashboard renders behind /proxy/symphony/")


def assert_existing_symphony_api_proxy(port):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request("GET", "/proxy/symphony/api/v1/state", headers={"Host": "stream.cash"})
    response = conn.getresponse()
    body = response.read()
    conn.close()

    if response.status != 200:
        raise RuntimeError(f"expected proxied dashboard API response, got status={response.status}")

    payload = json.loads(body.decode("utf-8"))
    if "counts" not in payload:
        raise RuntimeError("proxied dashboard API response does not look like Symphony state payload")

    log("api proxy ok: /proxy/symphony/api/v1/state reaches the upstream dashboard API")


def assert_existing_symphony_websocket_proxy(port):
    websocket_key = base64.b64encode(os.urandom(16)).decode("ascii")

    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        request = "\r\n".join(
            [
                "GET /proxy/symphony/live/websocket?vsn=2.0.0 HTTP/1.1",
                "Host: stream.cash",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {websocket_key}",
                "Sec-WebSocket-Version: 13",
                "",
                "",
            ]
        )
        sock.sendall(request.encode("ascii"))

        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)

    header_block = response.split(b"\r\n\r\n", 1)[0].decode("ascii")
    if "101 Switching Protocols" not in header_block:
        raise RuntimeError(f"expected websocket 101, got:\n{header_block}")

    log("websocket proxy ok: /proxy/symphony/live/websocket upgrades through nginx")


def run_runtime_smoke():
    upstream_port = 4101
    listen_port = free_port()
    temp_parent = REPO_ROOT / ".tmp"
    temp_parent.mkdir(exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="symphony-nginx-smoke-", dir=temp_parent) as temp_root:
        temp_root_path = pathlib.Path(temp_root)
        nginx_bin = find_or_download_nginx(temp_root_path)
        nginx_conf = temp_root_path / "nginx.conf"
        write_nginx_config(nginx_conf, listen_port)
        server = None
        server_thread = None
        use_existing_symphony = False

        try:
            server = ThreadingTCPServer(("127.0.0.1", upstream_port), ProxyUpstreamHandler)
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
        except OSError as error:
            if error.errno != 98:
                raise
            if not detect_existing_symphony():
                raise RuntimeError("port 4101 is already busy and does not appear to be a local Symphony dashboard") from error
            use_existing_symphony = True
            log("port 4101 is already busy; reusing the existing local Symphony dashboard for proxy smoke")

        try:
            try:
                subprocess.run(
                    [str(nginx_bin), "-t", "-p", temp_root, "-c", str(nginx_conf)],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
            except subprocess.CalledProcessError as error:
                raise RuntimeError(f"temporary nginx -t failed:\n{error.stdout}") from error

            with ManagedProcess(
                [str(nginx_bin), "-p", temp_root, "-c", str(nginx_conf), "-g", "daemon off;"],
                cwd=temp_root,
            ):
                wait_for_http(listen_port, "/proxy/symphony/")
                assert_redirect(listen_port)
                if use_existing_symphony:
                    assert_existing_symphony_http_proxy(listen_port)
                    assert_existing_symphony_api_proxy(listen_port)
                    assert_existing_symphony_websocket_proxy(listen_port)
                else:
                    assert_http_proxy(listen_port)
                    assert_websocket_proxy(listen_port)
        finally:
            if server is not None:
                server.shutdown()
                server.server_close()
            if server_thread is not None:
                server_thread.join(timeout=5)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Validate the versioned stream.cash nginx proxy contract for Symphony."
    )
    parser.add_argument(
        "--contract-only",
        action="store_true",
        help="only validate the committed nginx include without starting a disposable runtime",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    validate_contract()

    if args.contract_only:
        log("runtime smoke skipped (--contract-only)")
        return

    run_runtime_smoke()
    log("nginx smoke passed")


if __name__ == "__main__":
    main()
