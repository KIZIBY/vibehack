#!/usr/bin/env bash
# secret-patterns.sh — ЕДИНЫЙ ИСТОЧНИК секрет-паттернов.
#
# Доставляется вместе с .githooks/pre-commit. Sourceable-константа, НИЧЕГО при source не исполняет.
#
# ЗАЧЕМ ОБЩИЙ ФАЙЛ: это один canonical regex для всех секрет-границ:
#   - .githooks/pre-commit гардит staged строки;
#   - agent-preflight и intake применяют тот же corpus до issue transport;
#   - agent-publish-main сверяет политику из публикуемого HEAD.
# Sourceable consumers читают константу напрямую; issue-consumers читают файл через
# no-follow descriptor. У хука есть inline-fallback на случай отсутствия файла
# (никогда не ослаблять секрет-гард — fail-CLOSED).
#
# Паттерны (точные — НЕ generic `sk-`, иначе ложные срабатывания):
#   sk-live-       — Stripe live-ключ;
#   AKIA…          — AWS access key id;
#   BEGIN … KEY    — PEM private key заголовок;
#   sk-ant-api03-  — Anthropic API key (Claude-рантайм);
#   sk-ant-admin01-— Anthropic admin key;
#   sk-proj-       — OpenAI project key (Codex-рантайм).
#   ghp_            — GitHub classic personal access token;
#   github_pat_     — GitHub fine-grained personal access token.
#   scheme://u:p@   — password-bearing URL userinfo, не provider metadata/config (`ssh://git@` допустим).
#
# ЕДИНСТВЕННОЕ МЕСТО ПРАВКИ. Добавляешь паттерн — только здесь; все consumers подхватят.
SECRET_RE='sk-live-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY|sk-ant-api03-[A-Za-z0-9_-]{20,}|sk-ant-admin01-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,}|[A-Za-z][A-Za-z0-9+.-]*://[^/?#@[:space:]]+:[^/?#@[:space:]]+@'
