#!/usr/bin/env bash
# Starts the orders example twice: once with a valid environment (checks
# /healthz and that /config hides the secret), once with PORT=0 and no
# DATABASE_URL (checks that boot fails cleanly and names both problems).
# With the valid environment it also posts webhooks signed with each key of
# a key set that is mid-rotation, and last it checks that an empty webhook
# key fails at boot without printing a key.
set -euo pipefail
cd "$(dirname "$0")"

port="${SMOKE_PORT:-18080}"
secret="postgres://orders:smoke-secret-4f2a@localhost:5432/orders"
# Two webhook keys: the old one and, mid-rotation, the new one.
old_key="old-webhook-key-0123456789abcdef0123"
new_key="new-webhook-key-0123456789abcdef0123"

mix compile --warnings-as-errors >/dev/null

if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
  echo "FAIL: port $port is already in use; set SMOKE_PORT" >&2
  exit 1
fi

echo "== valid environment"
PORT="$port" DATABASE_URL="$secret" WEBHOOK_KEYS="$old_key,$new_key" mix run --no-halt &
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
if grep -qE "smoke-secret-4f2a|webhook-key" <<<"$config"; then
  echo "FAIL: GET /config contains a secret" >&2
  exit 1
fi
grep -qF '"database_url":"***"' <<<"$config" || { echo "FAIL: GET /config does not redact database_url" >&2; exit 1; }
grep -qF '"webhook_keys":"***"' <<<"$config" || { echo "FAIL: GET /config does not redact webhook_keys" >&2; exit 1; }

# Mid-rotation, a webhook signed with either key is accepted, and one signed
# with any other key, or not at all, is not.
body='{"order":"42","status":"paid"}'
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$@" -d "$body" "http://127.0.0.1:$port/webhooks/payments"; }
code="$(post)"
[ "$code" = 401 ] || { echo "FAIL: an unsigned webhook got $code, want 401" >&2; exit 1; }
for key in "$old_key" "$new_key" "other-webhook-key-0123456789abcdef"; do
  sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$key" | sed 's/.*= //')"
  want=204; [ "${key#other}" != "$key" ] && want=401
  code="$(post -H "X-Signature: $sig")"
  [ "$code" = "$want" ] || { echo "FAIL: webhook signed with the ${key%%-*} key: got $code, want $want" >&2; exit 1; }
done
echo "POST /webhooks/payments: old and new key accepted, any other rejected"

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

echo "== an empty webhook key (a trailing comma)"
status=0
output="$(DATABASE_URL="$secret" WEBHOOK_KEYS="$old_key," mix run --no-halt 2>&1)" || status=$?
echo "$output"
[ "$status" -eq 1 ] || { echo "FAIL: want exit status 1 for an empty webhook key, got $status" >&2; exit 1; }
grep -qF "docuconf: 1 configuration problem:" <<<"$output" || { echo "FAIL: no problem summary" >&2; exit 1; }
grep -qF "WEBHOOK_KEYS [out_of_range]: key 2 is empty" <<<"$output" || { echo "FAIL: no WEBHOOK_KEYS out_of_range for the empty key 2" >&2; exit 1; }
if grep -qF "webhook-key" <<<"$output"; then
  echo "FAIL: the error output contains a webhook key" >&2
  exit 1
fi

echo "smoke test passed"
