# shop: a docuconf example

One program that runs as two workloads, a `web` server and a queue `worker`,
configured by a contract written by hand and loaded in
[contract-first mode](../../README.md#contract-first-mode)
(`Docuconf.Contract`). It shows three parts of the spec:

- **roles** (SPEC §4.9): `DOCUCONF_ROLE` picks the role, and an input marked
  with roles is required only in those. The web server needs
  `ALLOWED_ORIGINS`, the worker needs `QUEUES`, and neither needs the
  other's.
- **`requiredIf`** (SPEC §4.2.1): `LOG_SCHEMA_URL` is required while
  `LOG_FORMAT` is `json`, and the `webhook-signing-key` file while
  `WEBHOOKS_ENABLED` is `true` (in the worker; the web server never reads
  it).
- **an included fragment** (SPEC §4.8): the contract includes `otel@1`,
  whose `OTEL_*` variables are inline in `vars` and checked at boot like the
  app's own.

It has no server, database or queue, and needs no Hex packages: it builds
against the SDK in this repository (`{:docuconf, path: "../.."}`).

- [`lib/shop.ex`](lib/shop.ex) loads the contract at start, prints one line
  and exits 0, or lists every problem and exits 1.
- [`test/shop_test.exs`](test/shop_test.exs) runs the test matrix below
  (`mix test`).
- [`contract.json`](contract.json) is the contract, the same in every
  docuconf SDK's shop example. `Shop` reads it when it compiles
  (`@external_resource`, so editing it recompiles) and loads it at every
  start:

  ```elixir
  Docuconf.Contract.load(@contract)
  ```

- [`contract.cue`](contract.cue) is the same contract in CUE, for `cue vet`
  and the platform. It is generated: `./contract-cue.sh` rewrites it from
  `contract.json`, and CI fails if it is out of date.

The SDK's `use Docuconf` declarations cannot declare roles, `requiredIf` or
fragments yet, so this example is contract-first, unlike
[`examples/orders`](../orders).

| Input | Type | Rules |
|---|---|---|
| `DOCUCONF_ROLE` | enum | `web` or `worker`; required |
| `DATABASE_URL` | url | secret, required, scheme `postgres` or `postgresql` |
| `PORT` | int | `web` only; 1–65535, default `8080` |
| `ALLOWED_ORIGINS` | list of strings (comma-separated) | `web` only; required |
| `QUEUES` | list of strings (comma-separated) | `worker` only; required |
| `WEBHOOKS_ENABLED` | bool | `worker` only; default `false` |
| `LOG_FORMAT` | enum | `text` or `json`; default `text` |
| `LOG_SCHEMA_URL` | url | scheme `https`; required when `LOG_FORMAT` is `json` |
| `OTEL_*` | from `otel@1` | optional; `OTEL_EXPORTER_OTLP_PROTOCOL` is one of `grpc`, `http/protobuf`, `http/json` |
| `webhook-signing-key` (file) | text | `worker` only; secret, at `/etc/shop/webhooks/signing.key`, at least 32 characters; required when `WEBHOOKS_ENABLED` is `true` |

Lists are comma-separated on the wire, the contract's default encoding.
Files are read under `DOCUCONF_FILE_ROOT` when it is set.

## Run it

Requires Elixir 1.18 or later.

```sh
cd examples/shop
export DATABASE_URL=postgres://shop@db:5432/shop
DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example mix run -e "Shop.main()"
DOCUCONF_ROLE=worker QUEUES=default,mail mix run -e "Shop.main()"
```

prints

```
shop web: port 8080, origins https://shop.example
shop worker: queues default,mail, webhooks off
```

The worker prints `webhooks on` when `WEBHOOKS_ENABLED=true` and the signing
key is at `$DOCUCONF_FILE_ROOT/etc/shop/webhooks/signing.key`.

## When the configuration is wrong

With JSON logs but no `LOG_SCHEMA_URL`, the worker does not start. Every
problem is reported at once on standard error, with a stable error code, no
stack trace and never a secret value, and the process exits with status 1:

```
$ DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json mix run -e "Shop.main()"
docuconf: 1 configuration problem:
  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"
```

In Kubernetes the same report is written to `/dev/termination-log`.

## Test matrix

[`test/shop_test.exs`](test/shop_test.exs) runs every case (`mix test`),
each from `DATABASE_URL=postgres://shop@db:5432/shop` with a fresh, empty
`DOCUCONF_FILE_ROOT`. A failing case must report exactly the problems
listed, and not print `DATABASE_URL`.

| # | Env (plus the base) | Expected |
|---|---|---|
| 1 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example` | ok: `shop web: port 8080, origins https://shop.example` |
| 2 | `DOCUCONF_ROLE=worker QUEUES=default,mail` | ok: `shop worker: queues default,mail, webhooks off`; the worker needs no `ALLOWED_ORIGINS` |
| 3 | `DOCUCONF_ROLE=web` | `ALLOWED_ORIGINS` `missing_required` |
| 4 | `QUEUES=default` (no role) | `DOCUCONF_ROLE` `missing_required`, and nothing else |
| 5 | `DOCUCONF_ROLE=cron` | `DOCUCONF_ROLE` `not_in_enum`, and nothing else |
| 6 | `DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json` | `LOG_SCHEMA_URL` `missing_required`: `is required when LOG_FORMAT is "json"` |
| 7 | as 6, plus `LOG_SCHEMA_URL=https://logs.example/v1.json` | ok |
| 8 | `DOCUCONF_ROLE=worker QUEUES=default WEBHOOKS_ENABLED=true`, no key file | `webhook-signing-key` `file_missing`: `..., and is required when WEBHOOKS_ENABLED is true` |
| 9 | as 8, with a 40-character key at `etc/shop/webhooks/signing.key` under the root | ok: `shop worker: queues default, webhooks on` |
| 10 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example WEBHOOKS_ENABLED=true` | ok: the key file belongs to the worker |
| 11 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example OTEL_EXPORTER_OTLP_PROTOCOL=carrier-pigeon` | `OTEL_EXPORTER_OTLP_PROTOCOL` `not_in_enum`: fragment variables are checked at boot |

[`smoke.sh`](smoke.sh) runs the real process (`mix run`) for cases 1, 2
and 6 and checks stdout, standard error and the exit status. CI runs both.

## Generated docs

[`CONFIG.md`](CONFIG.md) (for developers), [`CONFIG.agents.md`](CONFIG.agents.md)
(for AI agents) and `docs.json` (the docs model both are rendered from) are
generated from `contract.cue` by the `docuconf` CLI from
[docuconf-go](https://github.com/docuconf/docuconf-go). Never edit them by
hand. After changing `contract.json`, regenerate `contract.cue` and the docs
(CI runs each docs command with `--check` in place of `-o`):

```sh
./contract-cue.sh
docuconf docs contract.cue -o CONFIG.md
docuconf docs contract.cue --format agents -o CONFIG.agents.md
docuconf docs contract.cue --format model -o docs.json
```
