"""telemetry_html.py — статический HTML-дашборд телеметрии агентов (рендер для scripts/telemetry.py).

Вход — dict из telemetry.build_report (без путей машины и текста промптов); выход — один
самодостаточный HTML: inline CSS/SVG/JS, никаких внешних ресурсов. Палитра — валидированный
reference-инстанс dataviz (категориальные слоты в фиксированном порядке, статусы отдельно),
светлая/тёмная тема — свои шаги, не инверсия. Цвет модели закреплён за моделью (MODEL_ORDER),
а не за рангом. У каждого графика есть таблица-дубль, у каждой метки — hover-подсказка.
"""
import datetime as dt
import html

MODEL_ORDER = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
               "claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-opus-4-8"]
STATUS_LABEL = {"todo": "к работе", "doing": "в работе", "review": "ревью", "done": "готово", "blocked": "заблокирована"}
STATUS_VAR = {"todo": "--muted", "doing": "--s1", "review": "--s7", "done": "--good", "blocked": "--critical"}
REASON_LABEL = {"correction": "исправление курса", "approval": "одобрение", "question": "вопрос",
                "request": "новая просьба", "command": "slash-команда", "interrupt": "прерывание",
                "permission": "запрос разрешения", "answer": "ответ на вопрос агента",
                "manual-edit": "ручная правка кода", "empty": "пустой ввод"}

CSS = """
:root{color-scheme:light;--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;
--grid:#e1e0d9;--axis:#c3c2b7;--ring:rgba(11,11,11,.10);--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;
--s5:#e87ba4;--s6:#008300;--s7:#6250d6;--s8:#e34948;--good:#0ca30c;--warning:#fab219;--serious:#ec835a;
--critical:#d03b3b;--up:#006300}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){color-scheme:dark;--page:#0d0d0d;
--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#008300;--s7:#9085e9;--s8:#e66767;--up:#0ca30c}}
:root[data-theme="dark"]{color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;
--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;
--s5:#d55181;--s6:#008300;--s7:#9085e9;--s8:#e66767;--up:#0ca30c}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1240px;margin:0 auto;padding:24px 16px 48px}
header h1{font-size:22px;margin:0 0 4px;font-weight:600}
header p{margin:0;color:var(--ink2)}
.hero{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:20px 0}
.tile{background:var(--surface);border:1px solid var(--ring);border-radius:10px;padding:12px 14px;min-width:0}
.tile .l{color:var(--ink2);font-size:12px}
.tile .v{font-size:24px;font-weight:600;margin-top:2px}
.tile .s{color:var(--muted);font-size:12px}
.tile.big .v{font-size:48px;line-height:1.1}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,520px),1fr));gap:16px}
.card{background:var(--surface);border:1px solid var(--ring);border-radius:10px;padding:16px;min-width:0}
.card h2{font-size:15px;margin:0 0 2px;font-weight:600}
.card .sub{color:var(--ink2);font-size:12px;margin:0 0 12px}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;margin:0 0 10px;color:var(--ink2);font-size:12px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
.rows{display:grid;grid-template-columns:minmax(80px,max-content) 1fr max-content;gap:8px 10px;align-items:center}
.rows .lab{color:var(--ink2);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:220px}
.rows .val{font-size:12px;color:var(--ink);font-variant-numeric:tabular-nums;white-space:nowrap}
.track{display:flex;gap:2px;height:16px;align-items:stretch;min-width:0}
.seg{min-width:2px;height:100%}
.seg:last-child{border-radius:0 4px 4px 0}
.empty{color:var(--muted);font-size:13px;padding:12px 0}
svg{display:block;width:100%;max-width:680px;height:auto;overflow:visible}
svg text{fill:var(--muted);font:11px system-ui,-apple-system,"Segoe UI",sans-serif}
svg .gl{stroke:var(--grid);stroke-width:1}
svg .ax{stroke:var(--axis);stroke-width:1}
details{margin-top:10px;font-size:12px;color:var(--ink2)}
summary{cursor:pointer;color:var(--muted)}
table{border-collapse:collapse;width:100%;margin-top:6px;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:4px 8px 4px 0;border-bottom:1px solid var(--grid);font-size:12px;color:var(--ink)}
th{color:var(--ink2);font-weight:500}
.tasks td,.tasks th{padding-right:12px}
.pill{display:inline-block;padding:0 8px;border-radius:9px;font-size:11px;color:#fff}
.pill.todo{background:var(--muted)}.pill.doing{background:var(--s1)}.pill.review{background:var(--s7)}
.pill.done{background:var(--good)}.pill.blocked{background:var(--critical)}
.note{color:var(--muted);font-size:12px;margin-top:8px}
#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--surface);padding:4px 8px;border-radius:6px;
font-size:12px;opacity:0;transition:opacity .08s;z-index:9;max-width:320px}
"""

JS = """
(function(){var t=document.getElementById('tip');
document.addEventListener('pointermove',function(e){var n=e.target.closest&&e.target.closest('[data-tip]');
if(!n){t.style.opacity=0;return}t.textContent=n.getAttribute('data-tip');t.style.opacity=1;
var x=e.clientX+14,y=e.clientY+14;if(x+t.offsetWidth>innerWidth-8)x=e.clientX-t.offsetWidth-14;
if(y+t.offsetHeight>innerHeight-8)y=e.clientY-t.offsetHeight-14;t.style.left=x+'px';t.style.top=y+'px'})})();
"""


def esc(s):
    return html.escape("" if s is None else str(s), quote=True)


def short_model(m):
    return (m or "").replace("claude-", "")


def ftok(n):
    n = float(n or 0)
    for unit, div in (("M", 1e6), ("K", 1e3)):
        if n >= div:
            return ("%.1f" % (n / div)).rstrip("0").rstrip(".") + unit
    return "%d" % n


def fusd(v):
    v = float(v or 0)
    return "$%.2f" % v if v >= 0.01 or v == 0 else "$%.4f" % v


def model_colors(models):
    out, nxt = {}, 0
    known = [m for m in MODEL_ORDER if m in models]
    rest = sorted(m for m in models if m not in MODEL_ORDER)
    for m in known + rest:
        slot = MODEL_ORDER.index(m) + 1 if m in MODEL_ORDER else None
        if slot is None or slot > 8:
            nxt += 1
            slot = min(len(MODEL_ORDER) + nxt, 8)
        out[m] = "var(--s%d)" % slot
    return out


def legend(items):
    return '<div class="legend">%s</div>' % "".join(
        '<span><i style="background:%s"></i>%s</span>' % (c, esc(l)) for l, c in items)


def card(title, sub, body, table=None):
    t = ""
    if table:
        head, rows = table
        t = "<details><summary>Таблица</summary><table><tr>%s</tr>%s</table></details>" % (
            "".join("<th>%s</th>" % esc(h) for h in head),
            "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(c) for c in r) for r in rows))
    return '<section class="card"><h2>%s</h2><p class="sub">%s</p>%s%s</section>' % (esc(title), esc(sub), body, t)


def bars(rows, fmt=str, empty="Пока нет данных"):
    """rows: [(label, [(series_label, value, color)], total_label)] — горизонтальные (stacked) бары."""
    rows = [r for r in rows if sum(v for _, v, _ in r[1]) > 0]
    if not rows:
        return '<div class="empty">%s</div>' % esc(empty)
    mx = max(sum(v for _, v, _ in segs) for _, segs, _ in rows) or 1
    out = ['<div class="rows">']
    for label, segs, total in rows:
        cells = "".join('<div class="seg" style="flex:0 0 %.3f%%;background:%s" data-tip="%s"></div>' % (
            100.0 * v / mx, c, esc("%s · %s: %s" % (label, sl, fmt(v)))) for sl, v, c in segs if v > 0)
        out.append('<div class="lab" title="%s">%s</div><div class="track">%s</div><div class="val">%s</div>' % (
            esc(label), esc(label), cells, esc(total)))
    out.append("</div>")
    return "".join(out)


def _t(s):
    try:
        return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _hm(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%d.%m %H:%M")


def line_chart(series, yfmt=str, ymin=None, ymax=None, step=False, empty="Пока нет данных"):
    """series: [(name, color, [(ts_iso, value)])] — линии 2px, end-dot r=4 с кольцом поверхности."""
    pts_all = [(_t(x), y) for _, _, pts in series for x, y in pts if _t(x) is not None and y is not None]
    if not pts_all:
        return '<div class="empty">%s</div>' % esc(empty)
    W, H, L, R, T, B = 560, 200, 44, 70, 10, 26
    xs = [p[0] for p in pts_all]
    ys = [p[1] for p in pts_all]
    x0, x1 = min(xs), max(xs)
    if x1 - x0 < 60:
        x0, x1 = x0 - 30, x1 + 30
    lo = min(ys) if ymin is None else ymin
    hi = max(ys) if ymax is None else ymax
    if hi - lo < 1e-9:
        hi = lo + 1
    sx = lambda x: L + (x - x0) / (x1 - x0) * (W - L - R)  # noqa: E731
    sy = lambda y: T + (1 - (y - lo) / (hi - lo)) * (H - T - B)  # noqa: E731
    out = ['<svg viewBox="0 0 %d %d" role="img">' % (W, H)]
    for i in range(5):
        yv = lo + (hi - lo) * i / 4
        y = sy(yv)
        out.append('<line class="gl" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (L, W - R, y, y))
        out.append('<text x="%d" y="%.1f" text-anchor="end">%s</text>' % (L - 6, y + 4, esc(yfmt(yv))))
    out.append('<line class="ax" x1="%d" x2="%d" y1="%d" y2="%d"/>' % (L, W - R, H - B, H - B))
    for xv, anchor in ((x0, "start"), (x1, "end")):
        out.append('<text x="%.1f" y="%d" text-anchor="%s">%s</text>' % (sx(xv), H - 8, anchor, esc(_hm(xv))))
    for name, color, pts in series:
        p = sorted((_t(x), y) for x, y in pts if _t(x) is not None and y is not None)
        if not p:
            continue
        d, prev = [], None
        for x, y in p:
            if prev is not None and step:
                d.append("L%.1f %.1f" % (sx(x), sy(prev)))
            d.append(("M" if not d else "L") + "%.1f %.1f" % (sx(x), sy(y)))
            prev = y
        out.append('<path d="%s" fill="none" stroke="%s" stroke-width="2" stroke-linejoin="round" '
                   'stroke-linecap="round"/>' % (" ".join(d), color))
        for x, y in p:
            out.append('<circle cx="%.1f" cy="%.1f" r="9" fill="transparent" data-tip="%s"/>' % (
                sx(x), sy(y), esc("%s · %s: %s" % (name, _hm(x), yfmt(y)))))
        x, y = p[-1]
        out.append('<circle cx="%.1f" cy="%.1f" r="4" fill="%s" stroke="var(--surface)" stroke-width="2" '
                   'pointer-events="none"/>' % (sx(x), sy(y), color))
        out.append('<text x="%.1f" y="%.1f" style="fill:var(--ink2)">%s</text>' % (sx(x) + 8, sy(y) + 4, esc(yfmt(y))))
    out.append("</svg>")
    return "".join(out)


def tests_strip(series):
    if not series:
        return '<div class="empty">Тестов пока не запускали</div>'
    W, H, L, R = 560, 64, 10, 10
    ts = [_t(r["ts"]) for r in series if _t(r["ts"]) is not None]
    x0, x1 = min(ts), max(ts)
    if x1 - x0 < 60:
        x0, x1 = x0 - 30, x1 + 30
    out = ['<svg viewBox="0 0 %d %d" role="img">' % (W, H),
           '<line class="ax" x1="%d" x2="%d" y1="32" y2="32"/>' % (L, W - R)]
    for r in series:
        x = L + (_t(r["ts"]) - x0) / (x1 - x0) * (W - L - R)
        ok = r["status"] == "pass"
        tip = "%s · %s%s%s" % (_hm(_t(r["ts"])), "✓ зелёный" if ok else "✗ красный",
                               " · прошло %s" % r["passed"] if r.get("passed") is not None else "",
                               " · упало %s" % r["failed"] if r.get("failed") is not None else "")
        y = 20 if ok else 44
        out.append('<circle cx="%.1f" cy="%d" r="5" fill="var(%s)" stroke="var(--surface)" stroke-width="2" '
                   'data-tip="%s"/>' % (x, y, "--good" if ok else "--critical", esc(tip + (" · " + r["task"] if r.get("task") else ""))))
    out.append('<text x="%d" y="14">✓ зелёные</text><text x="%d" y="62">✗ красные</text>' % (L, L))
    out.append("</svg>")
    return "".join(out)


def tile(label, value, sub="", big=False):
    return '<div class="tile%s"><div class="l">%s</div><div class="v">%s</div><div class="s">%s</div></div>' % (
        " big" if big else "", esc(label), esc(value), esc(sub))


def render(r):
    tok, cost, git, tasks = r["tokens"], r["cost"], r["git"], r["tasks"]
    models = sorted(tok["by_model"], key=lambda m: -tok["by_model"][m]["total"])
    mc = model_colors(models)
    auto = r["autonomy"]
    rv = r["review"]
    iv = r["interventions"]

    hero = "".join([
        tile("Задачи, закрытые AI без ручной правки", "%.0f%%" % auto["pct"] if auto["pct"] is not None else "—",
             "%d из %d готовых" % (auto["ai_only"], auto["tasks_done"]), big=True),
        tile("Стоимость", fusd(cost["total_usd"]), "API-эквивалент по прайсу"),
        tile("Токены", ftok(tok["total"]["total"]), "выход %s · кэш %s" % (ftok(tok["total"]["output"]), ftok(tok["total"]["cache_read"]))),
        tile("Активное время", "%.0f мин" % r["active_time"]["minutes"], "%d ходов · %d сессий" % (r["active_time"]["turns"], r["active_time"]["sessions"])),
        tile("Коммиты · PR", "%d · %d" % (git["commits"], git["prs"]), "из них AI: %d" % git["ai_commits"]),
        tile("Ревью с первого раза", "%s" % ("%.0f%%" % rv["first_pass_pct"] if rv["first_pass_pct"] is not None else "—"),
             "кругов на задачу: %s" % (rv["avg_rounds"] if rv["avg_rounds"] is not None else "—")),
        tile("Вмешательства человека", "%d" % iv["total"], "прерываний: %d" % iv["by_reason"].get("interrupt", 0)),
    ])

    cards = []
    # 1 — токены по моделям и ролям
    roles = sorted(tok["by_role"], key=lambda k: -tok["by_role"][k]["total"])
    role_rows = []
    for role in roles:
        segs = []
        for m in models:
            v = tok["by_role_model"].get("%s · %s" % (role, m), {}).get("total", 0)
            segs.append((short_model(m), v, mc[m]))
        role_rows.append((role, segs, ftok(tok["by_role"][role]["total"])))
    cards.append(card("Токены по моделям и ролям", "Все токены запроса (вход + выход + кэш), роль = тип субагента",
                      (legend([(short_model(m), mc[m]) for m in models]) if len(models) > 1 else "") + bars(role_rows, ftok),
                      (["роль", "модель", "вход", "выход", "кэш-чтение", "кэш-запись", "всего", "$"],
                       [[k.split(" · ")[0], short_model(k.split(" · ")[1]), v["input"], v["output"], v["cache_read"],
                         v["cache_write"], v["total"], "%.4f" % v["usd"]] for k, v in sorted(tok["by_role_model"].items())])))
    # 2 — стоимость по моделям
    cards.append(card("Стоимость по моделям", cost["basis"] + (
        " · нет цены: " + ", ".join(tok["unpriced_models"]) if tok["unpriced_models"] else ""),
        bars([(short_model(m), [("стоимость", cost["by_model"].get(m, 0), mc[m])], fusd(cost["by_model"].get(m, 0)))
              for m in sorted(models, key=lambda m: -cost["by_model"].get(m, 0))], fusd),
        (["модель", "$"], [[short_model(m), "%.4f" % cost["by_model"].get(m, 0)] for m in models])))
    # 3 — токены во времени
    tl = tok["timeline"]
    cards.append(card("Токены во времени", "Вход + выход по 15-минутным окнам, по моделям",
                      (legend([(short_model(m), mc[m]) for m in models]) if len(models) > 1 else "") + line_chart(
                          [(short_model(m), mc[m], [(b["ts"], b["by_model"].get(m, 0)) for b in tl]) for m in models],
                          ftok, ymin=0)))
    # 4 — строки кода
    loc, lg = r["loc"]["ai_tools"], r["loc"]["git"]
    cards.append(card("Строки кода от AI", "Инструменты Edit/Write (structuredPatch) и git по трейлеру Co-Authored-By",
                      legend([("добавлено", "var(--s1)"), ("удалено", "var(--s2)")]) + bars([
                          ("AI · инструменты", [("добавлено", loc["added"], "var(--s1)"), ("удалено", loc["removed"], "var(--s2)")],
                           "+%d / −%d" % (loc["added"], loc["removed"])),
                          ("AI · коммиты", [("добавлено", lg["ai_added"], "var(--s1)"), ("удалено", lg["ai_removed"], "var(--s2)")],
                           "+%d / −%d" % (lg["ai_added"], lg["ai_removed"])),
                          ("человек · коммиты", [("добавлено", lg["human_added"], "var(--s1)"), ("удалено", lg["human_removed"], "var(--s2)")],
                           "+%d / −%d" % (lg["human_added"], lg["human_removed"]))]) +
                      '<p class="note">Файлов затронуто AI: %d</p>' % loc["files"]))
    # 5 — принятые и отклонённые правки
    ed = r["edits"]
    verd = rv["verdicts"]
    cards.append(card("Принятые и отклонённые правки AI", "Правки инструментами и вердикты ревьюеров",
                      bars([("правки: принято", [("принято", ed["accepted"], "var(--good)")], "✓ %d" % ed["accepted"]),
                            ("правки: отклонено", [("отклонено", ed["rejected"], "var(--critical)")], "✗ %d" % ed["rejected"]),
                            ("правки: поправлены", [("поправлены человеком", ed["user_modified"], "var(--serious)")], "✎ %d" % ed["user_modified"]),
                            ("ревью: APPROVE", [("APPROVE", verd.get("APPROVE", 0), "var(--good)")], "✓ %d" % verd.get("APPROVE", 0)),
                            ("ревью: BLOCK", [("BLOCK", verd.get("BLOCK", 0), "var(--critical)")], "✗ %d" % verd.get("BLOCK", 0))],
                           empty="Правок и ревью пока нет")))
    # 6 — задачи по статусам
    bs = tasks["by_status"]
    cards.append(card("Задачи по статусам", "todo → в работе → ревью → готово",
                      bars([(STATUS_LABEL[s], [(STATUS_LABEL[s], bs.get(s, 0), "var(%s)" % STATUS_VAR[s])], str(bs.get(s, 0)))
                            for s in ("todo", "doing", "review", "done", "blocked")], empty="Задач пока нет")))
    # 7 — круги ревью
    rpt = rv["rounds_per_task"]
    cards.append(card("Круги ревью на задачу", "С первого раза: %s · среднее кругов: %s" % (
        "%.0f%%" % rv["first_pass_pct"] if rv["first_pass_pct"] is not None else "—",
        rv["avg_rounds"] if rv["avg_rounds"] is not None else "—"),
        bars([(k, [("кругов", v, "var(--s7)")], str(v)) for k, v in rpt.items()], empty="Ревью пока не было")))
    # 8 — тесты во времени
    ts = r["tests"]
    cards.append(card("Тесты: красные и зелёные во времени",
                      "Прогонов %d · ✗ %d · ✓ %d · задач с RED до кода %d · зелёных в итоге %d из %d" % (
                          ts["runs"], ts["red"], ts["green"], ts["tasks_red_before_code"], ts["tasks_green_final"],
                          ts["tasks_with_tests"]), tests_strip(ts["series"])))
    # 9 — баги до мержа
    b = r["bugs"]
    cards.append(card("Баги, пойманные до мержа", "Находки ревьюера (P0–P2 / BLOCK) и красные прогоны тестов",
                      bars([("ревьюер", [("ревьюер", b["by_review"], "var(--s7)")], str(b["by_review"])),
                            ("тесты", [("тесты", b["by_tests"], "var(--s1)")], str(b["by_tests"])),
                            ("человек", [("человек", b["by_human"], "var(--s2)")], str(b["by_human"])),
                            ("в проде", [("в проде", b["in_prod"], "var(--critical)")], str(b["in_prod"]))],
                           empty="Багов пока не поймано")))
    # 10 — вмешательства
    cards.append(card("Вмешательства человека", "Каждое касание после постановки задачи, по причинам",
                      bars([(REASON_LABEL.get(k, k), [("раз", v, "var(--s1)")], str(v))
                            for k, v in sorted(iv["by_reason"].items(), key=lambda kv: -kv[1])], empty="Вмешательств нет")))
    # 11 — MAST
    m = r["mast"]
    fc_rows = []
    for fc, name in m["categories"].items():
        codes = [c for c in m["by_code"] if m["labels"][c]["fc"] == fc]
        closed = sum(m["by_code"][c]["closed"] for c in codes)
        total = sum(m["by_code"][c]["count"] for c in codes)
        fc_rows.append(("%s · %s" % (fc, name), [("закрыто правилом", closed, "var(--good)"),
                                                ("открыто", total - closed, "var(--serious)")], "%d / %d" % (closed, total)))
    cand = ", ".join("%s %s ×%d" % (k, m["labels"][k]["name"], v) for k, v in m["candidates"].items())
    cards.append(card("Ошибки по категориям MAST", "Подтверждённые ошибки и сколько закрыто правилом",
                      legend([("закрыто правилом", "var(--good)"), ("открыто", "var(--serious)")]) +
                      bars(fc_rows, empty="Подтверждённых ошибок нет") +
                      ('<p class="note">Авто-кандидаты (подтвердить или отбросить): %s</p>' % esc(cand) if cand else ""),
                      (["код", "режим", "ошибок", "закрыто"],
                       [[c, m["labels"][c]["name"], v["count"], v["closed"]] for c, v in sorted(m["by_code"].items())])))
    # 12 — плейбук
    pb = r["playbook"]
    cards.append(card("Правила в плейбуке во времени", "Пункты docs/pipeline-rules.md по истории git · новых через лог: %d" % pb["logged_rules"],
                      line_chart([("правил", "var(--s1)", [(p["ts"], p["rules"]) for p in pb["series"]])],
                                 lambda v: "%.0f" % v, ymin=0, step=True)))
    # 13 — прогноз и факт
    items = tasks["items"]
    has_human = any(it.get("human_estimate_min") is not None for it in items.values())

    def forecast_rows(tid, it):
        rows = [(tid + " · прогноз", [("прогноз", it["estimate_min"] or 0, "var(--muted)")],
                 "%g мин" % it["estimate_min"] if it["estimate_min"] is not None else "—")]
        if it.get("human_estimate_min") is not None:  # METR: сколько это заняло бы у человека без AI
            rows.append((tid + " · человек", [("человек", it["human_estimate_min"], "var(--s2)")],
                         "%g мин" % it["human_estimate_min"]))
        rows.append((tid + " · факт", [("факт", it["actual_min"] or 0, "var(--s1)")],
                     "%s мин" % it["actual_min"] if it["actual_min"] is not None else "—"))
        return rows
    rows_html = bars(sum([forecast_rows(tid, it) for tid, it in items.items()], []), lambda v: "%g мин" % v,
                     empty="Задач с прогнозом пока нет")
    cards.append(card("Прогноз и факт времени по задачам",
                      "Идея METR: прогноз агента и оценка человека до старта против фактического времени",
                      legend([("прогноз", "var(--muted)")] + ([("человек", "var(--s2)")] if has_human else [])
                             + [("факт", "var(--s1)")]) + rows_html))
    # 13б — рутина → кандидаты в скрипты
    routine = r.get("routine") or []
    cards.append(card("Рутина → кандидаты в скрипты",
                      "Bash-команды, повторённые 3+ раз: оформить в scripts/ или скилл (Live-SWE-agent)",
                      bars([(x["cmd"], [("повторов", x["count"], "var(--s7)")], "×%d" % x["count"]) for x in routine],
                           empty="Повторяющейся рутины пока нет")))
    # 14 — эвалы
    ev = r["evals"]["series"]
    names = list(ev)[:3]
    cards.append(card("Эвал-скор по итерациям", "agent-eval (% resolved) и эвалы продукта (RAG / LLM-судья)",
                      (legend([(n, "var(--s%d)" % (i + 1)) for i, n in enumerate(names)]) if len(names) > 1 else "") +
                      line_chart([(n, "var(--s%d)" % (i + 1), [(p["ts"], p["score"]) for p in ev[n]]) for i, n in enumerate(names)],
                                 lambda v: "%.2f" % v, ymin=0, ymax=1, empty="Эвалов пока не было"),
                      (["набор", "итерация", "скор"], [[n, p["iteration"], p["score"]] for n in ev for p in ev[n]])))

    task_rows = "".join(
        "<tr><td>%s</td><td>%s</td><td><span class=\"pill %s\">%s</span></td><td>%s</td><td>%s</td><td>%s</td>"
        "<td>%s</td><td>%s</td><td>%s</td></tr>" % (
            esc(tid), esc(it["title"] or ""), esc(it["status"]), esc(STATUS_LABEL.get(it["status"], it["status"])),
            esc("%g" % it["estimate_min"] if it["estimate_min"] is not None else "—"),
            esc(it["actual_min"] if it["actual_min"] is not None else "—"), esc(it["active_min"]),
            esc(ftok(it["tokens"])), esc(fusd(it["usd"])), esc(it["review_rounds"]))
        for tid, it in items.items())
    tasks_tbl = card("Задачи", "Прогноз, факт, активное время, токены и ревью по каждой задаче",
                     '<table class="tasks"><tr><th>id</th><th>задача</th><th>статус</th><th>прогноз, мин</th>'
                     '<th>факт, мин</th><th>активно, мин</th><th>токены</th><th>$</th><th>кругов ревью</th></tr>%s</table>'
                     % task_rows if task_rows else '<div class="empty">Задач пока нет</div>')

    return """<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Телеметрия агентов</title>
<style>%s</style></head><body><main>
<header><h1>Телеметрия агентов</h1><p>Окно с %s · сгенерировано %s · событий %d · источник токенов: транскрипты Claude Code</p></header>
<div class="hero">%s</div><div class="grid">%s</div><div style="margin-top:16px">%s</div>
</main><div id="tip" role="tooltip"></div><script>%s</script></body></html>
""" % (CSS, esc(r["since"][:16].replace("T", " ")), esc(r["generated_at"][:16].replace("T", " ")), r["events"],
       hero, "".join(cards), tasks_tbl, JS)
