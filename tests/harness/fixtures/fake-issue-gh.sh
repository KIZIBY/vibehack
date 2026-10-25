#!/usr/bin/env bash
set -eu

state_dir="${FAKE_ISSUE_STATE_DIR:?}"
case "${1:-} ${2:-}" in
  "issue close")
    printf '%s\n' "$*" >> "$state_dir/gh-close.log"
    [ "${FAKE_GH_CLOSE_RC:-0}" -eq 0 ] || {
      printf 'close failed: FAKELIFECYCLESECRET1234567890\n' >&2
      exit "${FAKE_GH_CLOSE_RC}"
    }
    ;;
  "issue view")
    [ "${FAKE_GH_VIEW_RC:-0}" -eq 0 ] || {
      printf 'view failed: FAKELIFECYCLESECRET1234567890\n' >&2
      exit "${FAKE_GH_VIEW_RC}"
    }
    number="${3#\#}"
    printf '{"number":%s,"state":"%s","closedAt":%s}\n' \
      "$number" "${FAKE_GH_STATE:-CLOSED}" "${FAKE_GH_CLOSED_AT:-\"2026-08-07T06:00:00Z\"}"
    ;;
  *) exit 2 ;;
esac
