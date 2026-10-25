# Привяжи тикет к спеке

Спека `specs/001-int` создана, но тикет не заведён (`- Ticket: —`). Заведи тикет через
единый вход intake (backend `github` объявлен в `PROJECT.md`; `gh` уже на PATH в `bin/`) и
привяжи его к спеке.

<!-- eval:apply -->
PATH="$PWD/bin:$PATH" bash bin-sut/intake.sh ticket specs/001-int 'intake eval wish' >/dev/null 2>&1
<!-- /eval:apply -->
