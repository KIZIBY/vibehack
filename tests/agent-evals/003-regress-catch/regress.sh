#!/usr/bin/env bash
# PASS→PASS страж: mul 2 3 == 6 должно ОСТАТЬСЯ верным
. ./calc.sh 2>/dev/null || exit 1
[ "$(mul 2 3)" = "6" ] || exit 1
exit 0
