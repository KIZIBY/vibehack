"""Общие помощники идентификаторов и времени: ULID (26 символов, сортируется по времени) и ISO-время UTC."""
import re
from datetime import datetime, timedelta

ULID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")


def test_new_id_is_26_char_crockford_ulid():
    from app.common import new_id
    assert ULID_RE.match(new_id())


def test_new_id_unique_and_strictly_increasing_even_within_one_millisecond():
    from app.common import new_id
    ids = [new_id() for _ in range(20000)]
    assert len(set(ids)) == len(ids)
    assert ids == sorted(ids), "идентификаторы должны возрастать, в том числе внутри одной миллисекунды"


def test_new_id_time_prefix_follows_clock(monkeypatch):
    import app.common as common
    monkeypatch.setattr(common.time, "time", lambda: 1_700_000_000.0)
    first = common.new_id()
    monkeypatch.setattr(common.time, "time", lambda: 1_700_000_001.0)
    assert common.new_id() > first


def test_utc_now_iso_is_utc_and_sortable_as_text():
    from app.common import utc_now_iso
    first = utc_now_iso()
    parsed = datetime.fromisoformat(first)
    assert parsed.utcoffset() == timedelta(0)
    assert abs((datetime.now(parsed.tzinfo) - parsed).total_seconds()) < 5
    assert re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}\+00:00$", first)
    assert utc_now_iso() >= first
