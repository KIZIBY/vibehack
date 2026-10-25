# Ops Journal — append-only журнал эксплуатации (пишет scripts/ops-log.sh)

DORA-события: `deploy:start|done|failed` · `publish:done|failed` · `incident:open|resolved <slug>`;
читает `scripts/dora-metrics.sh`.

**Как писать.** Только дозапись строкой таблицы через `bash scripts/ops-log.sh <event> [detail]`
(символ `|` и переводы строк санируются; event/detail с путём машины или IPv4 отклоняются — журнал
лежит в git). Руками существующие строки не правятся и не удаляются: pre-commit блокирует любую
правку, кроме дозаписи в конец (устав I-2/I-3); `.gitattributes` даёт журналу `merge=union`.

**События** (списком: единственная таблица файла — журнал ниже, её читают парсеры):

- `deploy:done` / `deploy:failed` — detail `sha=… rc=…`. Пишет ТОЛЬКО деплой-скрипт проекта
  (`PROJECT.md §3`): `bash scripts/ops-log.sh deploy:done "sha=<sha>"`.
- `deploy:start` — деплой-скрипт проекта, если нужен замер длительности.
- `publish:done` / `publish:failed` — `scripts/agent-publish-main.sh` при публикации в main
  (verify-after-push), detail `sha=… rc=…` (+ `rebased-from=…`). Публикация — не деплой: DORA считает
  её поставкой, только если в журнале нет ни одного `deploy:*` события (у проекта нет деплой-шага).
- `incident:open <slug>` / `incident:resolved <slug>` — триаж инцидента
  (`docs/guides/OPERATIONS_GUIDE.md` §1); slug — ПЕРВОЕ слово detail (пара для MTTR).
- `publish:pr`, `publish:noop`, `publish:retry` — служебные события
  `scripts/agent-publish-main.sh`, вне DORA-счётчиков.
- `lease:take` / `lease:release` — `scripts/coordination-lease.sh`, detail `<slug> scope=… ttl=…`.
- `coord:notify` / `coord:ack` — уведомление параллельных сессий перед захватом общего ресурса
  (`docs/pipeline-rules.md`).

Произвольные события допустимы; DORA учитывает только `deploy:*`, `incident:*` и (как fallback без
деплоев) `publish:done|failed`.

**Известное ограничение (ретрай-пара).** Сетевой сбой между `git push` и verify даёт
`publish:failed`; агентский ретрай при уже доехавшем push даёт `publish:noop` — одна логически
успешная публикация может оставить «ложный» failed в Change Failure Rate. Принято осознанно,
автодедупликации нет.

| ts (UTC) | event | detail |
|---|---|---|
