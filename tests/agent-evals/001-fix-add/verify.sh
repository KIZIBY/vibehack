#!/usr/bin/env bash
# скрытый судья: add 2 3 должно быть 5
. ./calc.sh 2>/dev/null || exit 1
[ "$(add 2 3)" = "5" ] || exit 1
exit 0
