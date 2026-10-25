# hermes/ — AI-судья на Hermes Agent

Основа — [Hermes Agent](https://github.com/NousResearch/hermes-agent) (MIT) из официального образа
`nousresearch/hermes-agent` с закреплённым тегом. Исходников Hermes в репо нет: здесь только наш
обвес, который подключается к нему при деплое. Обновить Hermes — поменять тег в
`docker-compose.yml` (или `HERMES_VERSION=...`) и выкатить заново.

| Путь | Что | Как попадает в Hermes |
|---|---|---|
| `plugins/ai-judge/` | плагин: инструмент `judge_score` + хук-журнал оценок | том read-only → `/opt/data/plugins/ai-judge`, включён в `config.yaml` |
| `skills/ai-judge/SKILL.md` | навык: процедура оценки и рубрика | том read-only → `/opt/data/skills/ai-judge` |
| `config/SOUL.md` | личность судьи | копируется в `~/.hermes/SOUL.md` при деплое |
| `config/config.yaml` | наша часть конфига (плагины, approvals) | сливается с `~/.hermes/config.yaml` при деплое |
| `scripts/apply_overlay.py` | слияние конфига + SOUL.md | запускается `deploy.sh` внутри контейнера |
| `.env.example` | имена переменных | настоящий `.env` — только на сервере, `~/.hermes/.env` |

## Развёртывание на VPS

Команды — по SSH, не через браузерную консоль хостера (она портит `:` `@` `=` при вставке).

```bash
# 0. Docker и файрвол (Ubuntu 22.04/24.04, от 2 vCPU / 4 ГБ)
curl -fsSL https://get.docker.com | sh
sudo ufw allow OpenSSH && sudo ufw enable

# 1. Код
git clone https://github.com/KIZIBY/vibehack.git && cd vibehack && git switch ai-judge

# 2. Один раз: мастер настройки — ключ провайдера, модель, мессенджер → ~/.hermes/.env и config.yaml
mkdir -p ~/.hermes
cd hermes && docker compose run --rm hermes setup && cd ..

# 3. Выкатка (и каждое обновление: git pull && bash hermes/deploy.sh)
bash hermes/deploy.sh
```

Дашборд и API слушают только `127.0.0.1` (Docker публикует порты в обход ufw). Доступ — туннелем:
`ssh -L 9119:127.0.0.1:9119 <user>@<vps>` → `http://localhost:9119`. Если API шлюза нужен снаружи —
reverse proxy с TLS перед `127.0.0.1:8642` и `API_SERVER_KEY` в `.env`.

Для Telegram в `~/.hermes/.env` обязательно `TELEGRAM_ALLOWED_USERS` (числовые ID), иначе бот
открыт всем.

## Разработка обвеса

- **Новый инструмент** — схема в `plugins/ai-judge/schemas.py`, обработчик в `tools.py`
  (`handler(params, **kwargs) -> str` с JSON), регистрация в `__init__.py`, имя — в `plugin.yaml`
  `provides_tools`. Логику держите в чистых функциях без импорта Hermes — так её покрывают тесты.
  Инструменты плагинов Hermes держит за `tool_search` (модель видит их в каталоге и вызывает через
  мост). Если модель их не находит — `tools.tool_search.enabled: off` в `config/config.yaml`
  (все инструменты сразу в контексте, дороже по токенам).
- **Проверка плагина в живом Hermes** — `docker compose exec hermes hermes plugins doctor --ci ai-judge`.
- **Хуки** — `ctx.register_hook(...)` в `__init__.py`: `pre_tool_call` (может заблокировать вызов),
  `post_tool_call`, `pre_llm_call`, `post_llm_call`, `on_session_start`, `on_session_end`.
- **Рубрика и процедура** — `skills/ai-judge/SKILL.md`.
- **Новый навык или плагин** — новая подпапка + строка тома в `docker-compose.yml`
  (+ `plugins.enabled` в `config/config.yaml` для плагина).
- **Тесты** — `python3 -m unittest discover -s hermes/tests` из корня репо.

Слияние `config.yaml` только добавляет: элемент, удалённый из нашего списка, на сервере останется —
убирайте его там руками (`config.yaml.bak` — копия до последнего деплоя).

Документация Hermes: [Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker) ·
[Plugins](https://hermes-agent.nousresearch.com/docs/developer-guide/plugins) ·
[Hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks) ·
[Skills](https://hermes-agent.nousresearch.com/docs/developer-guide/creating-skills) ·
[Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)
