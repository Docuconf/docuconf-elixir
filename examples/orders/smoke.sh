#!/usr/bin/env bash
# Starts the orders example twice: once with a valid environment (checks
# /healthz and that /config hides the secret), once with PORT=0 and no
# DATABASE_URL (checks that boot fails cleanly and names both problems).
set -euo pipefail
cd "$(dirname "$0")"

port="${SMOKE_PORT:-18080}"
secret="postgres://orders:smoke-secret-4f2a@localhost:5432/orders"

mix compile --warnings-as-errors >/dev/null

if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
  echo "FAIL: port $port is already in use; set SMOKE_PORT" >&2
  exit 1
fi

echo "== valid environment"
PORT="$port" DATABASE_URL="$secret" mix run --no-halt &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

for _ in $(seq 60); do
  health="$(curl -fsS "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  [ "$health" = "ok" ] && break
  kill -0 "$pid" 2>/dev/null || { echo "FAIL: the app exited during startup" >&2; exit 1; }
  sleep 0.5
done
[ "$health" = "ok" ] || { echo "FAIL: GET /healthz returned '$health', want 'ok'" >&2; exit 1; }
echo "GET /healthz: $health"

config="$(curl -fsS "http://127.0.0.1:$port/config")"
echo "GET /config: $config"
if grep -qF "smoke-secret-4f2a" <<<"$config"; then
  echo "FAIL: GET /config contains the secret" >&2
  exit 1
fi
grep -qF '"database_url":"***"' <<<"$config" || { echo "FAIL: GET /config does not redact database_url" >&2; exit 1; }

kill "$pid"
wait "$pid" 2>/dev/null || true
trap - EXIT

echo "== PORT=0, no DATABASE_URL"
status=0
output="$(env -u DATABASE_URL PORT=0 mix run --no-halt 2>&1)" || status=$?
echo "$output"
[ "$status" -ne 0 ] || { echo "FAIL: the app started with an invalid environment" >&2; exit 1; }
for code in missing_required out_of_range; do
  grep -qF "$code" <<<"$output" || { echo "FAIL: the output does not mention $code" >&2; exit 1; }
done
if grep -qF "smoke-secret-4f2a" <<<"$output"; then
  echo "FAIL: the error output contains the secret" >&2
  exit 1
fi
# A clean failure: the problem list, no stack trace, no crash dump.
grep -qF "docuconf: 2 configuration problems:" <<<"$output" || { echo "FAIL: no problem summary" >&2; exit 1; }
if grep -qE '\*\* \(|erl_eval|stacktrace' <<<"$output"; then
  echo "FAIL: the error output has a stack trace" >&2
  exit 1
fi
[ ! -e erl_crash.dump ] || { echo "FAIL: erl_crash.dump was written" >&2; exit 1; }

echo "smoke test passed"
