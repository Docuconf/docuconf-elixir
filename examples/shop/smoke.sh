#!/usr/bin/env bash
# Runs the shop as a real process (mix run) for the README's cases 1, 2 and
# 6: the web role, the worker role, and JSON logs without LOG_SCHEMA_URL,
# which must fail at boot. Checks stdout, standard error and the exit
# status, and that DATABASE_URL is never printed.
set -euo pipefail
cd "$(dirname "$0")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
secret="postgres://shop@db:5432/shop"
# The contract's variables (the vars keys in contract.json), unset before
# each run so the caller's environment does not leak in.
unset_vars=()
for name in $(sed -n 's/^    "\([A-Z][A-Z0-9_]*\)": {$/\1/p' contract.json); do
  unset_vars+=(-u "$name")
done

mix compile --warnings-as-errors >/dev/null

# check STATUS STDOUT STDERR NAME=value...: runs the shop with the base env,
# the given variables and a fresh, empty file root, and wants exit status
# STATUS, exactly STDOUT, and the line STDERR (if not empty) in standard
# error.
check() {
  local want_status=$1 want_out=$2 want_err=$3 status=0
  shift 3
  mkdir "$tmp/root"
  env "${unset_vars[@]}" DATABASE_URL="$secret" DOCUCONF_FILE_ROOT="$tmp/root" \
    DOCUCONF_TERMINATION_LOG="$tmp/termination-log" "$@" \
    mix run -e "Shop.main()" >"$tmp/out" 2>"$tmp/err" || status=$?
  if [ "$status" != "$want_status" ] || [ "$(cat "$tmp/out")" != "$want_out" ]; then
    echo "FAIL: $*: want exit status $want_status and stdout '$want_out', got $status:" >&2
    cat "$tmp/out" "$tmp/err" >&2
    exit 1
  fi
  if [ -n "$want_err" ] && ! grep -qxF -- "$want_err" "$tmp/err"; then
    echo "FAIL: $*: standard error lacks the line '$want_err':" >&2
    cat "$tmp/err" >&2
    exit 1
  fi
  # A clean failure: the problem summary, and no stack trace.
  if [ "$want_status" != 0 ]; then
    grep -qE "^docuconf: [0-9]+ configuration problems?:$" "$tmp/err" ||
      { echo "FAIL: $*: no problem summary" >&2; cat "$tmp/err" >&2; exit 1; }
    if grep -qE '\*\* \(|stacktrace' "$tmp/err"; then
      echo "FAIL: $*: standard error has a stack trace" >&2
      exit 1
    fi
  fi
  if grep -qF "$secret" "$tmp/out" "$tmp/err"; then
    echo "FAIL: $*: DATABASE_URL was printed" >&2
    exit 1
  fi
  echo "ok: $* -> exit $status${want_out:+, $want_out}"
  rm -rf "$tmp/root" "$tmp/out" "$tmp/err" "$tmp/termination-log"
}

echo "== 1. web"
check 0 "shop web: port 8080, origins https://shop.example" "" \
  DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example

echo "== 2. worker: no ALLOWED_ORIGINS needed"
check 0 "shop worker: queues default,mail, webhooks off" "" \
  DOCUCONF_ROLE=worker QUEUES=default,mail

echo "== 6. JSON logs without LOG_SCHEMA_URL"
check 1 "" '  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"' \
  DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json

echo "smoke test passed"
