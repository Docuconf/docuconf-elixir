# orders: a docuconf example

A tiny HTTP service that declares its configuration with docuconf, validates
it at boot, and exports the contract the platform deploys against. It uses
OTP's own HTTP server (`:httpd`, from `:inets`), so it needs no Hex packages,
and builds against the SDK in this repository (`{:docuconf, path: "../.."}`).

- [`lib/orders/env.ex`](lib/orders/env.ex) declares every variable.
- [`config/runtime.exs`](config/runtime.exs) loads and validates them at boot.
- [`lib/orders/router.ex`](lib/orders/router.ex) serves `GET /healthz`
  (`ok`), `GET /config` (the typed values as JSON, secrets always redacted)
  and `POST /webhooks/payments` (a payment webhook signed with any key in
  `WEBHOOK_KEYS`, checked by [`lib/orders/webhook.ex`](lib/orders/webhook.ex)).
- [`test/webhook_test.exs`](test/webhook_test.exs) walks through a key
  rotation (`mix test`).
- [`contract.cue`](contract.cue) is the exported contract.

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default 8080 |
| `LOG_LEVEL` | enum (atoms in Elixir) | `debug`, `info`, `warning`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres`, at most 2048 characters |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration (`30s`, `1m30s`) | 1s–5m, default `30s` |
| `WORKER_COUNT` | int | 1–64, default 4 |
| `WEBHOOK_KEYS` | list of strings (comma-separated) | secret, optional; 1–2 keys of 32–256 characters each |

## Run it

Requires Elixir 1.18 or later.

```sh
cd examples/orders
DATABASE_URL=postgres://orders:orders@localhost:5432/orders mix run --no-halt
```

```sh
$ curl localhost:8080/healthz
ok
$ curl localhost:8080/config
{"port":8080,"log_level":"info","allowed_origins":["http://localhost:3000"],"database_url":"***","request_timeout":30000,"webhook_keys":"***","worker_count":4}
```

`request_timeout` is in milliseconds, the SDK's default unit for durations.

## When the configuration is wrong

With `PORT=0` and no `DATABASE_URL`, the app does not start. Every problem is
reported at once, with a stable error code and no stack trace, and the
process exits with status 1:

```
$ PORT=0 mix run --no-halt
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
```

In Kubernetes the same report is written to `/dev/termination-log`, so
`kubectl describe pod` shows it.

[`smoke.sh`](smoke.sh) checks both runs: the endpoints with a valid
environment, then this failure, and the webhook key set below.

## Rotate a key

`WEBHOOK_KEYS` is a key set: `POST /webhooks/payments` accepts a body whose
`X-Signature` header is the hex HMAC-SHA256 of the body under any key in the
list. A variable is read once, at start, so a new key reaches the service
only when the pods restart; with two keys valid at once, no webhook is turned
away while that happens:

1. Add the new key as the second item (`old,new` in the Secret), and roll out.
2. Switch the sender to the new key.
3. Remove the old key (`new`), and roll out.

In the platform's values, the key set is a reference to one Secret key that
holds `old,new` while rotating:

```yaml
WEBHOOK_KEYS:
  secretKeyRef: {name: orders-webhooks, key: keys}
```

The contract allows 1 or 2 keys of 32 to 256 characters each, so a trailing
comma or a truncated key stops the service at boot instead of locking out
the sender, without printing a key:

```
$ DATABASE_URL=postgres://orders:orders@localhost:5432/orders \
    WEBHOOK_KEYS=old-webhook-key-0123456789abcdef0123, mix run --no-halt
docuconf: 1 configuration problem:
  - WEBHOOK_KEYS [out_of_range]: item 2 is 0 characters, shorter than item_min_length 32
```

[docuconf-go's SPEC section 6.1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md#61-rotation)
covers rotation in general.

## Export the contract

```sh
mix docuconf.export          # writes contract.cue
mix docuconf.export --check  # fails if contract.cue is out of date (CI runs this)
```

`mix.exs` names the declaration module (`docuconf: [module: Orders.Env]`).
Never edit `contract.cue` by hand.

## Generated docs

[`CONFIG.md`](CONFIG.md) (for developers), [`CONFIG.agents.md`](CONFIG.agents.md)
(for AI agents) and `docs.json` (the docs model both are rendered from) are
generated from `contract.cue` by the `docuconf` CLI from
[docuconf-go](https://github.com/docuconf/docuconf-go). Never edit them by hand
either; regenerate them after exporting the contract (CI runs each with
`--check` in place of `-o`, against the committed `contract.cue`):

```sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```

## Deploy it

Ship `contract.cue` with the image. The platform validates its values against
it before anything runs: `docuconf vet` checks a deployment's values and
`docuconf render` turns them into the Kubernetes env and Secret references,
or a Helm-based platform uses the
[docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm/docuconf),
which generates a `values.schema.json` from the contract. Either way a missing
`DATABASE_URL` or an out-of-range `PORT` is caught at deploy time, and the
boot check above is the last line of defence.
