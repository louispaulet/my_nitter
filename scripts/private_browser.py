#!/usr/bin/env python3
"""Open a private Cloud Run Nitter service through an authenticated local proxy."""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


ROOT_DIR = Path(__file__).resolve().parent.parent
DEPLOY_ENV = ROOT_DIR / "deploy.env"


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        raise RuntimeError("deploy.env is missing. Copy deploy.env.example and configure the deployment.")
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def run_gcloud(*args: str) -> str:
    result = subprocess.run(
        ["gcloud", *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def safe_host(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    parsed = urlparse(value if "://" in value else f"https://{value}")
    return parsed.netloc.lower()


def fetch_service_metadata(project: str, region: str, service: str) -> tuple[str, set[str]]:
    raw = run_gcloud(
        "run", "services", "describe", service,
        f"--project={project}", f"--region={region}", "--format=json",
    )
    metadata = json.loads(raw)
    service_url = metadata.get("status", {}).get("url", "")
    if not service_url:
        raise RuntimeError("Cloud Run service has no URL.")

    hosts = {safe_host(service_url)}
    containers = metadata.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    for container in containers:
        for env in container.get("env", []):
            if env.get("name") == "NITTER_HOSTNAME" and env.get("value"):
                hosts.add(safe_host(env["value"]))

    try:
        domains = run_gcloud(
            "beta", "run", "domain-mappings", "list",
            f"--project={project}", f"--region={region}",
            "--format=json",
        )
    except subprocess.CalledProcessError:
        domains = ""
    if domains:
        domain_data = json.loads(domains)
        if isinstance(domain_data, dict):
            domain_data = domain_data.get("items", [])
        hosts.update(
            safe_host(mapping.get("metadata", {}).get("name", ""))
            for mapping in domain_data
            if mapping.get("spec", {}).get("routeName") == service
        )
    return service_url, {host for host in hosts if host}


def available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_listener(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("gcloud Cloud Run proxy exited before it was ready.")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("Timed out waiting for the gcloud Cloud Run proxy to start.")


class BrowserProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "PrivateNitterBrowserProxy"
    sys_version = ""
    proxy_port = 0
    browser_port = 0
    hostnames: set[str] = set()

    def log_message(self, _format: str, *_args: object) -> None:
        # Avoid recording private profile paths or search terms in local logs.
        return

    def _localize(self, value: str) -> str:
        local = f"http://127.0.0.1:{self.browser_port}"
        for hostname in self.hostnames:
            value = value.replace(f"https://{hostname}", local)
            value = value.replace(f"http://{hostname}", local)
            value = value.replace(f"//{hostname}", local)
        return value

    def _send_proxy_error(self) -> None:
        payload = b"The authenticated Cloud Run proxy is unavailable. Check the terminal running this helper.\n"
        self.send_response(502)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def _forward(self) -> None:
        body = b""
        content_length = self.headers.get("Content-Length")
        if content_length:
            try:
                body = self.rfile.read(int(content_length))
            except (ValueError, OSError):
                self._send_proxy_error()
                return

        blocked = {
            "accept-encoding", "connection", "host", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
            "authorization",
        }
        headers = {key: value for key, value in self.headers.items() if key.lower() not in blocked}
        upstream = http.client.HTTPConnection("127.0.0.1", self.proxy_port, timeout=180)
        try:
            upstream.request(self.command, self.path, body=body or None, headers=headers)
            response = upstream.getresponse()
        except (OSError, http.client.HTTPException):
            upstream.close()
            self._send_proxy_error()
            return

        response_headers = response.getheaders()
        content_type = next(
            (value for key, value in response_headers if key.lower() == "content-type"), ""
        ).lower()
        text_response = content_type.startswith("text/") or any(
            marker in content_type for marker in ("javascript", "json", "xml", "svg")
        )

        self.send_response(response.status, response.reason)
        upstream_length = next(
            (value for key, value in response_headers if key.lower() == "content-length"), None
        )
        for key, value in response_headers:
            if key.lower() in {"connection", "content-length", "content-encoding", "transfer-encoding"}:
                continue
            self.send_header(key, self._localize(value))

        if text_response:
            payload = response.read()
            for hostname in self.hostnames:
                for scheme in (b"https://", b"http://", b"//"):
                    payload = payload.replace(
                        scheme + hostname.encode("utf-8"),
                        f"http://127.0.0.1:{self.browser_port}".encode("ascii"),
                    )
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        else:
            if upstream_length is not None:
                self.send_header("Content-Length", upstream_length)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    while chunk := response.read(64 * 1024):
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        upstream.close()

    do_GET = _forward
    do_HEAD = _forward
    do_POST = _forward
    do_PUT = _forward
    do_PATCH = _forward
    do_DELETE = _forward
    do_OPTIONS = _forward


def main() -> int:
    if not shutil.which("gcloud"):
        print("ERROR: gcloud is required.", file=sys.stderr)
        return 1

    try:
        config = read_config(DEPLOY_ENV)
    except (RuntimeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    project = config.get("GCP_PROJECT_ID", "").strip()
    region = config.get("GCP_REGION", "europe-west1").strip() or "europe-west1"
    service = config.get("CLOUD_RUN_SERVICE", "my-nitter").strip() or "my-nitter"
    if not project:
        project = run_gcloud("config", "get-value", "project")
        if project == "(unset)":
            project = ""
    if not project:
        print("ERROR: Set GCP_PROJECT_ID in deploy.env or configure a gcloud project.", file=sys.stderr)
        return 1

    try:
        active_account = run_gcloud("auth", "list", "--filter=status:ACTIVE", "--format=value(account)")
    except subprocess.CalledProcessError:
        active_account = ""
    if not active_account:
        print("ERROR: gcloud is not authenticated. Run 'gcloud auth login'.", file=sys.stderr)
        return 1

    proxy: subprocess.Popen[bytes] | None = None
    try:
        _, hostnames = fetch_service_metadata(project, region, service)
        proxy_port = available_port()
        browser_port = int(os.environ.get("NITTER_BROWSER_PORT", "8080"))
        if not 1024 <= browser_port <= 65535:
            raise RuntimeError("NITTER_BROWSER_PORT must be between 1024 and 65535.")

        server = ThreadingHTTPServer(("127.0.0.1", browser_port), BrowserProxyHandler)
        BrowserProxyHandler.proxy_port = proxy_port
        BrowserProxyHandler.browser_port = browser_port
        BrowserProxyHandler.hostnames = hostnames

        proxy = subprocess.Popen(
            [
                "gcloud", "run", "services", "proxy", service,
                f"--project={project}", f"--region={region}", f"--port={proxy_port}",
            ],
        )
        try:
            wait_for_listener(proxy, proxy_port)
            print("Authenticated Nitter browser proxy is ready.")
            print(f"Cloud Run service: {service} ({region})")
            print(f"Browser URL: http://127.0.0.1:{browser_port}/")
            print("Keep this terminal open while using Nitter. Press Ctrl+C to stop.")
            server.serve_forever()
        finally:
            server.server_close()
            if proxy.poll() is None:
                proxy.terminate()
                try:
                    proxy.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proxy.kill()
                    proxy.wait()
        return 0
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    finally:
        if proxy is not None and proxy.poll() is None:
            proxy.terminate()
            try:
                proxy.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxy.kill()


if __name__ == "__main__":
    raise SystemExit(main())
