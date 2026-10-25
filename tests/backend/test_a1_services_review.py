"""Находки ревью (Codex) по ship/a1-services: тесты написаны ДО исправлений (RED).

- storage: повторная запись под тем же (project, kind, material_id, имя) не затирает файл молча -> FileExistsError;
- netguard: ``resolve_public_url(url, *, resolver)`` отдаёт проверенные адреса (клиент подключается к ним,
  а не резолвит имя повторно — защита от DNS rebinding между проверкой и запросом);
- intake_runner: ``inventory.json`` — не обычный файл (FIFO) не вешает раннер: ``bad_inventory``.
"""
from __future__ import annotations

import asyncio
import os
import signal
import socket
import sys
import textwrap

import pytest


def run(coro):
    return asyncio.run(coro)


async def chunked(data: bytes):
    yield data


def test_storage_does_not_overwrite_existing_material_file(tmp_path):
    from app.services.storage import Storage
    storage = Storage(tmp_path)
    first = run(storage.save_upload("p", "briefs", "a.txt", chunked(b"first"), max_bytes=100, material_id="m1"))
    with pytest.raises(FileExistsError):
        run(storage.save_upload("p", "briefs", "a.txt", chunked(b"second"), max_bytes=100, material_id="m1"))
    assert (tmp_path / first.path_rel).read_bytes() == b"first"
    assert [p.name for p in (tmp_path / "projects" / "p" / "briefs" / "m1").iterdir()] == ["a.txt"]
    other = run(storage.save_upload("p", "briefs", "b.txt", chunked(b"other"), max_bytes=100, material_id="m1"))
    assert (tmp_path / other.path_rel).read_bytes() == b"other"


def resolver_for(mapping):
    def resolver(host, port, *args, **kwargs):
        ips = mapping[host]
        return [(socket.AF_INET6 if ":" in ip else socket.AF_INET, socket.SOCK_STREAM, 6, "",
                 (ip, port, 0, 0) if ":" in ip else (ip, port)) for ip in ips]
    return resolver


def test_resolve_public_url_returns_validated_addresses():
    from app.services.netguard import resolve_public_url
    resolver = resolver_for({"example.com": ["93.184.216.34", "93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]})
    target = resolve_public_url("HTTPS://Example.com/x#f", resolver=resolver)
    assert target.url == "https://example.com/x"
    assert target.addresses == ("2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34")


def test_resolve_public_url_literal_ip_and_rejections():
    from app.services.netguard import UnsafeUrl, resolve_public_url
    assert resolve_public_url("http://93.184.216.34:81/", resolver=resolver_for({})).addresses == ("93.184.216.34",)
    with pytest.raises(UnsafeUrl):
        resolve_public_url("http://rebind.example.com/", resolver=resolver_for({"rebind.example.com": ["93.184.216.34", "10.0.0.1"]}))
    with pytest.raises(UnsafeUrl):
        resolve_public_url("http://127.0.0.1/", resolver=resolver_for({}))


def test_fifo_inventory_does_not_hang(tmp_path):
    from app.services.intake_runner import IntakeFailed, IntakeRunner
    fake = tmp_path / "fake.py"
    fake.write_text(textwrap.dedent('''
        import os, sys
        from pathlib import Path
        out = Path(sys.argv[3])
        out.mkdir(parents=True, exist_ok=True)
        os.mkfifo(out / "inventory.json")
    '''), encoding="utf-8")
    submission = tmp_path / "submission"
    submission.mkdir()

    async def scenario():
        runner = IntakeRunner(command=[sys.executable, str(fake)], timeout=30)
        return await asyncio.wait_for(runner.run(submission, tmp_path / "out"), 10)

    class Hung(BaseException):
        pass

    def on_alarm(signum, frame):
        raise Hung("раннер завис на inventory.json (FIFO)")

    previous = signal.signal(signal.SIGALRM, on_alarm)     # блокирующий open не прерывается wait_for
    signal.alarm(10)
    try:
        with pytest.raises(IntakeFailed) as info:
            run(scenario())
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
    assert info.value.reason == "bad_inventory"
