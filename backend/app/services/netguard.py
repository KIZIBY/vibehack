"""Защита от SSRF: ссылка пользователя должна вести только на публичные адреса.

Проверка делается на каждом шаге (исходный URL и каждый редирект). Остаточный риск, который закрывает
вызывающий код: между проверкой и самим запросом DNS-ответ может смениться (rebinding), поэтому клиент,
который ходит по ссылке, должен подключаться к проверенным адресам, а не резолвить имя повторно.
"""
import ipaddress
import re
import socket
from typing import Callable, Sequence
from urllib.parse import quote, urljoin, urlsplit

MAX_URL_LENGTH = 2048
MAX_REDIRECTS = 5
ALLOWED_SCHEMES = ("http", "https")
RESERVED_SUFFIXES = (".localhost", ".internal", ".local")
_FORBIDDEN_CHARS = re.compile(r"[\x00-\x20\x7f\\]")
_NUMERIC_LABEL = re.compile(r"[0-9]+|0[xX][0-9a-fA-F]*")
_LABEL = re.compile(r"[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?")
_NAT64 = ipaddress.ip_network("64:ff9b::/96")


class UnsafeUrl(ValueError):
    """Ссылка недопустима: схема, адрес, формат или число редиректов."""


def _is_public_ip(ip) -> bool:
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return _is_public_ip(ip.ipv4_mapped)
        if ip in _NAT64:
            return _is_public_ip(ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF))
        if ip.is_site_local:
            return False
        if ip.sixtofour is not None:
            return _is_public_ip(ip.sixtofour) and ip.is_global
    return (ip.is_global and not ip.is_multicast and not ip.is_private and not ip.is_loopback
            and not ip.is_link_local and not ip.is_reserved and not ip.is_unspecified)


def _check_name(host: str) -> str:
    if not host.isascii():
        try:
            host = host.encode("idna").decode("ascii")
        except UnicodeError:
            raise UnsafeUrl("недопустимое имя хоста") from None
    host = host.lower()
    if len(host) > 253:
        raise UnsafeUrl("слишком длинное имя хоста")
    labels = host.split(".")
    if len(labels) < 2 or not all(_LABEL.fullmatch(label) for label in labels):
        raise UnsafeUrl("недопустимое имя хоста")
    if host.endswith(RESERVED_SUFFIXES):
        raise UnsafeUrl("служебное имя хоста")
    return host


def validate_public_url(url: str, *, resolver: Callable = socket.getaddrinfo) -> str:
    """Возвращает нормализованный URL или бросает UnsafeUrl."""
    if not isinstance(url, str) or not url or len(url) > MAX_URL_LENGTH:
        raise UnsafeUrl("недопустимая ссылка")
    if _FORBIDDEN_CHARS.search(url) or any(ch.isspace() for ch in url):
        raise UnsafeUrl("недопустимые символы в ссылке")
    try:
        parts = urlsplit(url)
        port = parts.port
        raw_host = parts.hostname
    except ValueError:
        raise UnsafeUrl("недопустимая ссылка") from None
    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise UnsafeUrl("разрешены только http и https")
    if "@" in parts.netloc:
        raise UnsafeUrl("логин и пароль в ссылке запрещены")
    if not raw_host:
        raise UnsafeUrl("в ссылке нет хоста")
    if port == 0:
        raise UnsafeUrl("недопустимый порт")

    if parts.netloc.startswith("["):                       # IPv6-литерал
        try:
            ip = ipaddress.ip_address(raw_host)
        except ValueError:
            raise UnsafeUrl("недопустимый IPv6-адрес") from None
        if not _is_public_ip(ip):
            raise UnsafeUrl("адрес не публичный")
        host_text = f"[{ip}]"
    else:
        host = raw_host.rstrip(".")
        if not host:
            raise UnsafeUrl("в ссылке нет хоста")
        if _NUMERIC_LABEL.fullmatch(host.rsplit(".", 1)[-1]):   # IP в любой записи: разрешён только обычный a.b.c.d
            try:
                ip = ipaddress.IPv4Address(host)
            except ValueError:
                raise UnsafeUrl("недопустимая запись IP-адреса") from None
            if not _is_public_ip(ip):
                raise UnsafeUrl("адрес не публичный")
            host_text = str(ip)
        else:
            host_text = _check_name(host)
            _check_resolution(host_text, port or (443 if scheme == "https" else 80), resolver)

    path = quote(parts.path or "/", safe="/%:@!$&'()*+,;=~-._")
    query = quote(parts.query, safe="/%:@!$&'()*+,;=~-._?")
    netloc = host_text + (f":{port}" if port is not None else "")
    return f"{scheme}://{netloc}{path}" + (f"?{query}" if parts.query else "")


def _check_resolution(host: str, port: int, resolver: Callable) -> None:
    try:
        infos = resolver(host, port, type=socket.SOCK_STREAM)
    except Exception:
        raise UnsafeUrl("хост не резолвится") from None
    addresses = [info[4][0] for info in infos or ()]
    if not addresses:
        raise UnsafeUrl("хост не резолвится")
    for address in addresses:       # ВСЕ ответы должны быть публичными (DNS rebinding)
        try:
            ip = ipaddress.ip_address(str(address).split("%", 1)[0])
        except ValueError:
            raise UnsafeUrl("недопустимый адрес в ответе DNS") from None
        if not _is_public_ip(ip):
            raise UnsafeUrl("хост указывает на непубличный адрес")


def validate_redirect(location: str, base_url: str, *, resolver: Callable = socket.getaddrinfo) -> str:
    """Проверяет цель редиректа: относительный ``Location`` склеивается с базой."""
    if not isinstance(location, str) or not location.strip():
        raise UnsafeUrl("пустой редирект")
    return validate_public_url(urljoin(base_url, location), resolver=resolver)


def check_redirect_chain(urls: Sequence[str]) -> None:
    """``urls`` — цели уже пройденных редиректов; больше MAX_REDIRECTS нельзя."""
    if len(urls) > MAX_REDIRECTS:
        raise UnsafeUrl("слишком много редиректов")
