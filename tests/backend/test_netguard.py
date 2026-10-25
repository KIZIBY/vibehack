"""T031 (часть): защита от SSRF ``app.services.netguard``. Тесты написаны ДО реализации (RED). Сети нет:
резолвер подменяется.

Контракт:
- ``validate_public_url(url, *, resolver=socket.getaddrinfo) -> str`` — нормализованный URL (схема и хост в
  нижнем регистре, без фрагмента, пустой путь -> ``/``) или ``UnsafeUrl(ValueError)``;
- только http/https, без userinfo, хост резолвится и ВСЕ адреса публичные; литеральные и «обфусцированные»
  IP разбираются самим модулем (не полагаясь на резолвер); длина URL ≤ 2048;
- ``validate_redirect(location, base_url, *, resolver=...) -> str`` — относительный ``Location`` склеивается с
  базой и проходит ту же проверку;
- ``check_redirect_chain(urls)`` — ``urls`` = цели уже пройденных редиректов; больше 5 -> ``UnsafeUrl``.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import inspect
import socket

import pytest

PUBLIC_V4 = "93.184.216.34"
PUBLIC_V6 = "2606:2800:220:1:248:1893:25c8:1946"


def fake_resolver(mapping=None, default=None, calls=None):
    """Резолвер в формате getaddrinfo; ``default`` — адрес для неизвестных хостов (None -> gaierror)."""
    mapping = mapping or {}

    def resolver(host, port, *args, **kwargs):
        if calls is not None:
            calls.append(host)
        ips = mapping.get(host, default)
        if ips is None:
            raise socket.gaierror(socket.EAI_NONAME, "unknown host")
        if isinstance(ips, str):
            ips = [ips]
        result = []
        for ip in ips:
            if ":" in ip:
                result.append((socket.AF_INET6, socket.SOCK_STREAM, 6, "", (ip, port or 0, 0, 0)))
            else:
                result.append((socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port or 0)))
        return result

    return resolver


def public(host_ips=None):
    return fake_resolver(host_ips or {}, default=PUBLIC_V4)


def validate(url, resolver=None):
    from app.services.netguard import validate_public_url
    return validate_public_url(url, resolver=resolver or public())


def rejected(url, resolver=None):
    from app.services.netguard import UnsafeUrl, validate_public_url
    assert issubclass(UnsafeUrl, ValueError)
    with pytest.raises(UnsafeUrl):
        validate_public_url(url, resolver=resolver or public())


def test_default_resolver_is_getaddrinfo():
    from app.services.netguard import validate_public_url
    assert inspect.signature(validate_public_url).parameters["resolver"].default is socket.getaddrinfo


# --- допустимые ------------------------------------------------------------------------------------------


def test_public_url_accepted_and_normalized():
    assert validate("HTTPS://Example.COM/Path?q=1#frag") == "https://example.com/Path?q=1"
    assert validate("http://example.com") == "http://example.com/"
    assert validate("http://example.com:8080/a") == "http://example.com:8080/a"


def test_public_literals_accepted():
    assert validate("http://" + PUBLIC_V4 + "/x") == "http://" + PUBLIC_V4 + "/x"
    assert validate("http://[" + PUBLIC_V6 + "]/x") == "http://[" + PUBLIC_V6 + "]/x"


def test_public_ipv6_resolution_accepted():
    resolver = fake_resolver({"v6.example.com": [PUBLIC_V6, PUBLIC_V4]})
    assert validate("https://v6.example.com/", resolver) == "https://v6.example.com/"


def test_url_length_boundary():
    prefix = "http://example.com/"
    ok = prefix + "a" * (2048 - len(prefix))
    assert len(ok) == 2048 and validate(ok) == ok
    rejected(ok + "a")


# --- схема, userinfo, формат -----------------------------------------------------------------------------


@pytest.mark.parametrize("url", [
    "ftp://example.com/x", "file:///etc/passwd", "gopher://example.com/", "javascript:alert(1)",
    "data:text/html;base64,AAAA", "//example.com/x", "example.com/x", "", "   ", "http:///x", "http://",
    "https://:443/", "mailto:a@example.com",
])
def test_bad_scheme_or_shape(url):
    rejected(url)


@pytest.mark.parametrize("url", [None, 42, b"http://example.com"])
def test_non_string_rejected(url):
    from app.services.netguard import UnsafeUrl, validate_public_url
    with pytest.raises(UnsafeUrl):
        validate_public_url(url, resolver=public())


def test_userinfo_rejected():
    login = "user"
    secret = "pw"
    rejected("http://" + login + ":" + secret + "@example.com/")
    rejected("http://" + login + "@example.com/")
    rejected("http://@example.com/")


@pytest.mark.parametrize("url", [
    "http://exa mple.com/", "http://example.com/\nHost: evil", "http://example.com/\x00", "http://example.com\\@127.0.0.1/",
    "http://example.com/\tx", "http://example.com:99999/", "http://example.com:abc/", "http://example.com:0/",
])
def test_control_chars_backslash_and_bad_port(url):
    rejected(url)


# --- запрещённые адреса ----------------------------------------------------------------------------------


@pytest.mark.parametrize("host", [
    "127.0.0.1", "127.255.255.254", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
    "169.254.0.1", "100.64.0.1", "100.127.255.255", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
    "0.0.0.0", "192.0.0.1", "198.18.0.1",
])
def test_private_ipv4_literals_rejected(host):
    rejected("http://" + host + "/")


@pytest.mark.parametrize("host", [
    "[::1]", "[::]", "[fd00::1]", "[fc00::1]", "[fe80::1]", "[ff02::1]", "[::ffff:10.0.0.1]", "[::ffff:127.0.0.1]",
    "[::ffff:7f00:1]", "[::ffff:a9fe:a9fe]", "[64:ff9b::7f00:1]", "[2002:7f00:1::]",
])
def test_private_ipv6_literals_rejected(host):
    rejected("http://" + host + "/")


@pytest.mark.parametrize("host", ["2130706433", "0177.0.0.1", "0x7f.1", "0x7f000001", "127.1", "017700000001", "0x7f.0.0.1",
                                  "0300.0250.0.1", "167772161", "2852039166", "0xA9FEA9FE"])
def test_obfuscated_ip_rejected_even_if_resolver_says_public(host):
    # резолвер «разрешает» всё в публичный адрес: защита не должна на него полагаться
    rejected("http://" + host + "/", fake_resolver(default=PUBLIC_V4))


@pytest.mark.parametrize("host", [
    "localhost", "LOCALHOST", "localhost.", "app.localhost", "a.b.localhost", "db.internal", "svc.cluster.internal",
    "printer.local", "host.local.", "INTERNAL",
])
def test_reserved_names_rejected_even_if_resolver_says_public(host):
    rejected("http://" + host + "/", fake_resolver(default=PUBLIC_V4))


@pytest.mark.parametrize("ip", ["127.0.0.1", "10.1.2.3", "169.254.169.254", "100.64.0.9", "::1", "fd12::1", "fe80::2",
                                "::ffff:10.0.0.1", "0.0.0.0"])
def test_hostname_resolving_to_private_rejected(ip):
    rejected("https://innocent.example.com/", fake_resolver({"innocent.example.com": ip}))


@pytest.mark.parametrize("addrs", [
    [PUBLIC_V4, "10.0.0.5"], ["10.0.0.5", PUBLIC_V4], [PUBLIC_V4, "127.0.0.1", PUBLIC_V6], [PUBLIC_V6, "fd00::1"],
    [PUBLIC_V4, "169.254.169.254"],
])
def test_rebinding_like_mixed_answers_rejected(addrs):
    rejected("https://rebind.example.com/", fake_resolver({"rebind.example.com": addrs}))


def test_resolution_failure_and_empty_answer_rejected():
    rejected("http://nonexistent.example.com/", fake_resolver())
    rejected("http://empty.example.com/", fake_resolver({"empty.example.com": []}))

    def broken(host, port, *args, **kwargs):
        raise OSError("dns down")

    rejected("http://example.com/", broken)


def test_resolver_gets_ascii_host_for_idn():
    calls = []
    resolver = fake_resolver(default=PUBLIC_V4, calls=calls)
    result = validate("https://пример.рф/путь", resolver)
    assert calls and all(host.isascii() for host in calls)
    assert result.startswith("https://xn--") and "пример" not in result.split("/")[2]


# --- редиректы -------------------------------------------------------------------------------------------


def test_validate_redirect_relative_joined_with_base():
    from app.services.netguard import validate_redirect
    resolver = public()
    assert validate_redirect("/next?a=1", "https://example.com/start/page", resolver=resolver) == "https://example.com/next?a=1"
    assert validate_redirect("sibling", "https://example.com/dir/page", resolver=resolver) == "https://example.com/dir/sibling"
    assert validate_redirect("https://other.example.org/x", "https://example.com/", resolver=resolver) == "https://other.example.org/x"


@pytest.mark.parametrize("location", [
    "http://127.0.0.1/admin", "http://169.254.169.254/latest/meta-data/", "//10.0.0.1/x", "file:///etc/passwd",
    "http://localhost:8000/", "http://[::1]/", "gopher://example.com/", "", "http://2130706433/",
])
def test_validate_redirect_rejects_unsafe_targets(location):
    from app.services.netguard import UnsafeUrl, validate_redirect
    with pytest.raises(UnsafeUrl):
        validate_redirect(location, "https://example.com/start", resolver=public())


def test_validate_redirect_rechecks_resolution():
    from app.services.netguard import UnsafeUrl, validate_redirect
    resolver = fake_resolver({"evil.example.org": "10.9.9.9"}, default=PUBLIC_V4)
    with pytest.raises(UnsafeUrl):
        validate_redirect("https://evil.example.org/", "https://example.com/", resolver=resolver)


def test_redirect_chain_limit_is_five():
    from app.services.netguard import UnsafeUrl, check_redirect_chain
    urls = ["https://example.com/%d" % i for i in range(6)]
    check_redirect_chain([])
    check_redirect_chain(urls[:5])
    with pytest.raises(UnsafeUrl):
        check_redirect_chain(urls)
