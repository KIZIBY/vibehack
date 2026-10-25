from __future__ import annotations

import ipaddress
import socket
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


MAX_BYTES = 100 * 1024 * 1024
TIMEOUT_SECONDS = 20
MAX_ATTEMPTS = 3


class SSRFBlocked(ValueError):
    pass


class FetchFailed(RuntimeError):
    pass


@dataclass
class FetchResult:
    url: str
    status: int
    content_type: str
    size_bytes: int
    attempts: int
    output: str


def _public_host(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise SSRFBlocked("only http/https URLs are allowed")
    host = parsed.hostname
    try:
        addresses = [ipaddress.ip_address(host)]
    except ValueError:
        try:
            addresses = [ipaddress.ip_address(item[4][0]) for item in socket.getaddrinfo(host, parsed.port or 443, type=socket.SOCK_STREAM)]
        except socket.gaierror as exc:
            raise FetchFailed(f"DNS lookup failed: {host}") from exc
    if any(address.is_private or address.is_loopback or address.is_link_local or address.is_multicast or address.is_reserved or address.is_unspecified for address in addresses):
        raise SSRFBlocked(f"private or reserved address blocked: {host}")


class PublicRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        _public_host(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_url(url: str, output: str | Path, *, max_bytes: int = MAX_BYTES, timeout: int = TIMEOUT_SECONDS, attempts: int = MAX_ATTEMPTS) -> FetchResult:
    _public_host(url)
    output = Path(output)
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            request = Request(url, headers={"User-Agent": "ai-judge-intake/1.0"})
            with build_opener(PublicRedirects()).open(request, timeout=timeout) as response:
                content_length = int(response.headers.get("Content-Length", "0") or 0)
                if content_length > max_bytes:
                    raise FetchFailed(f"response exceeds size limit: {max_bytes} bytes")
                output.parent.mkdir(parents=True, exist_ok=True)
                size = 0
                with output.open("wb") as handle:
                    while chunk := response.read(min(1024 * 1024, max_bytes - size + 1)):
                        size += len(chunk)
                        if size > max_bytes:
                            raise FetchFailed(f"response exceeds size limit: {max_bytes} bytes")
                        handle.write(chunk)
                return FetchResult(response.geturl(), response.status, response.headers.get_content_type(), size, attempt, output.as_posix())
        except (HTTPError, URLError, TimeoutError, OSError, FetchFailed) as exc:
            last_error = exc
            if isinstance(exc, SSRFBlocked):
                raise
            if attempt < attempts:
                time.sleep(min(2 ** (attempt - 1), 4))
    raise FetchFailed(f"fetch failed after {attempts} attempts: {last_error}") from last_error
