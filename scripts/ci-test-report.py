#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Стриминговый репортер для self-test сьюта tests/harness/run-tests.sh.

Читает stdout сьюта ПОСТРОЧНО (пайп) и одновременно:
  • пишет ПОЛНЫЙ лог в файл (артефакт CI);
  • показывает в консоль ЧИСТЫЙ прогресс — секции, счётчик пройденных, и КАЖДОЕ
    падение сразу (без простыни из тысяч `ok`);
  • в конце печатает итоговый бокс (проценты, прогресс-бар, список «что доработать»);
  • пишет JUnit XML → вкладка тестов любого CI, читающего JUnit (pass/fail, дрилл-даун).

usage: bash tests/harness/run-tests.sh 2>&1 | ci-test-report.py <run-tests.log> [report.xml]

Сам скрипт всегда exit 0 — реальный код сьюта берётся из ${PIPESTATUS[0]} в CI.
"""
import sys
import re
import html

LOGFILE = sys.argv[1] if len(sys.argv) > 1 else "run-tests.log"
XMLFILE = sys.argv[2] if len(sys.argv) > 2 else "report.xml"

RE_SECTION = re.compile(r'^──\s*(.+?)\s*──\s*$')
RE_OK = re.compile(r'^ok\s+(.+)$')
RE_FAIL = re.compile(r'^FAIL\s+(.+)$')
RE_DETAIL = re.compile(r'^\s+\|\s?(.*)$')

C = "\033[36m"; G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"
B = "\033[1m"; DIM = "\033[2m"; RST = "\033[0m"

results = []          # (section, name, failure_detail|None)
section = "general"
sec_ok = 0
cur_fail = None       # [section, name, [detail...]]
saw_total = False     # видели строку "ИТОГ:" → сьют дошёл до конца (иначе оборвался под set -u)


def emit(s=""):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


def close_section():
    global sec_ok
    if sec_ok:
        emit("   %s+ %d passed%s" % (DIM, sec_ok, RST))
    sec_ok = 0


def close_fail():
    global cur_fail
    if cur_fail:
        results.append((cur_fail[0], cur_fail[1],
                        "\n".join(cur_fail[2]) if cur_fail[2] else ""))
        cur_fail = None


log = open(LOGFILE, "w", encoding="utf-8")
for raw in sys.stdin:
    log.write(raw)
    line = raw.rstrip("\n")
    if line.startswith("ИТОГ:"):
        saw_total = True

    m = RE_SECTION.match(line)
    if m:
        close_fail(); close_section()
        section = m.group(1)
        emit(""); emit("%s|> %s%s" % (B + C, section, RST))
        continue

    m = RE_OK.match(line)
    if m:
        close_fail()
        results.append((section, m.group(1).strip(), None))
        sec_ok += 1
        continue

    m = RE_FAIL.match(line)
    if m:
        close_fail()
        name = m.group(1).strip()
        cur_fail = [section, name, []]
        emit("   %sFAIL%s %s" % (R + B, RST, name))
        continue

    m = RE_DETAIL.match(line)
    if m and cur_fail is not None:
        cur_fail[2].append(m.group(1))
        emit("       %s%s%s" % (DIM, m.group(1)[:140], RST))
        continue

    # прочие строки сьюта (диагностика/echo) — показываем как есть
    if line.strip():
        emit("   %s%s%s" % (DIM, line[:160], RST))

close_fail(); close_section()
log.close()

# ── подсчёты ─────────────────────────────────────────────────────────────────
total = len(results)
failed = sum(1 for _, _, fd in results if fd is not None)
passed = total - failed
rate = (passed / total * 100.0) if total else 0.0

# ── JUnit XML ────────────────────────────────────────────────────────────────
def esc(s):
    return html.escape(s or "", quote=True)

suites = {}
order = []
for sec, name, fd in results:
    suites.setdefault(sec, [])
    if sec not in order:
        order.append(sec)
    suites[sec].append((name, fd))

xml = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<testsuites name="run-tests.sh" tests="%d" failures="%d">' % (total, failed)]
for sec in order:
    cases = suites[sec]
    sf = sum(1 for _, fd in cases if fd is not None)
    xml.append('  <testsuite name="%s" tests="%d" failures="%d">' % (esc(sec), len(cases), sf))
    for name, fd in cases:
        if fd is None:
            xml.append('    <testcase classname="%s" name="%s"/>' % (esc(sec), esc(name)))
        else:
            first = (fd.splitlines() or [""])[0][:200]
            xml.append('    <testcase classname="%s" name="%s"><failure message="%s">%s</failure></testcase>'
                       % (esc(sec), esc(name), esc(first), esc(fd)))
    xml.append('  </testsuite>')
xml.append('</testsuites>')
with open(XMLFILE, "w", encoding="utf-8") as fh:
    fh.write("\n".join(xml) + "\n")

# ── итоговый бокс ────────────────────────────────────────────────────────────
BAR = 40
filled = int(round(BAR * passed / total)) if total else 0
bar = G + "#" * filled + RST + DIM + "." * (BAR - filled) + RST
col = G if failed == 0 else (Y if rate >= 90 else R)

emit(""); emit("")
emit(B + C + "=" * 60 + RST)
emit(B + "  РЕЗУЛЬТАТ  " + RST + DIM + "tests/harness/run-tests.sh" + RST)
emit("  [%s]  %s%s%.1f%%%s" % (bar, col, B, rate, RST))
emit("  %s+ passed %d%s    %s- failed %d%s    всего %d"
     % (G, passed, RST, (R if failed else DIM), failed, RST, total))
emit(B + C + "=" * 60 + RST)

if not saw_total:
    emit(""); emit(R + B + "  ⚠ СЬЮТ ОБОРВАЛСЯ до ИТОГ (краш/abort под set -u — см. последние строки выше)" + RST)
    emit(R + B + "  X гейт КРАСНЫЙ" + RST)
elif failed:
    emit(""); emit(Y + B + "  НАДО ДОРАБОТАТЬ (%d):" % failed + RST)
    n = 0
    for sec, name, fd in results:
        if fd is not None:
            n += 1
            emit("  %s%2d.%s %s-%s %s[%s]%s %s" % (DIM, n, RST, R, RST, C, sec, RST, name))
            first = (fd.splitlines() or [""])[0].strip() if fd else ""
            if first:
                emit("      %s^ %s%s" % (DIM, first[:120], RST))
    emit("")
    emit(R + B + "  X гейт КРАСНЫЙ — мёрдж в main заблокирован" + RST)
else:
    emit(""); emit(G + B + "  OK ВСЁ ЗЕЛЁНОЕ — можно мёрджить" + RST)
emit("")
