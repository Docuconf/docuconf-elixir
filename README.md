# docuconf for Elixir

Typed configuration contracts for Elixir applications, from the
[docuconf specification](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md) (v1alpha1).

Elixir apps read their runtime configuration in `config/runtime.exs` with
`System.fetch_env!/1` and `System.get_env/2`. That is the host this SDK
extends. You keep `runtime.exs` and `config :my_app, ...`, and you get:

- one declaration, in the NimbleOptions style, of every environment variable
  and file the app reads, with types, constraints, descriptions and secrets;
- validation at boot, with **every** problem reported together under a
  stable error code, secret values never printed, and the report also
  written to `/dev/termination-log` so `kubectl describe pod` shows it;
- boot checks for files: JSON/YAML/TOML config against a JSON Schema, TLS
  key pairs (key match, expiry, DNS names, key algorithm, chain to the CA),
  CA bundles, PKCS#12/JKS keystores, text and binary files;
- `mix docuconf.export`, which writes `contract.cue`, a CUE document the
  platform validates before it deploys anything.

There are no runtime dependencies. JSON comes from Elixir 1.18's `JSON`
module and certificate handling from OTP's `:public_key`.

## Install

```elixir
def deps do
  [{:docuconf, "~> 0.1"}]
end
```

Requires Elixir 1.18 or later, on OTP 25 or later.

## Example

```elixir
defmodule MyApp.Env do
  use Docuconf, name: "orders"

  env :port, :integer, description: "HTTP listen port", default: 4000, min: 1, max: 65535

  secret :database_url, :url,
    description: "Primary Postgres connection string",
    required: true,
    schemes: ["postgres", "ecto"]

  env :checkout_timeout, :duration, description: "Checkout request timeout", default: "15s"
  env :allowed_origins, {:list, :string}, description: "CORS origins", min_items: 1

  config_file :pricing,
    format: :json,
    description: "Pricing rules: currency and discount tiers",
    required: true,
    path: "/etc/orders/pricing/pricing.json",
    schema: [
      currency: [type: :string, required: true, pattern: "^[A-Z]{3}$"],
      tiers: [type: {:list, {:map, [min_total: [type: :pos_integer, required: true]]}}]
    ]

  tls_file :serving_tls,
    description: "Certificate the API serves HTTPS with",
    required: true,
    path: "/etc/orders/tls",
    dns_names: ["orders.internal"],
    min_remaining: "720h"
end
```

```elixir
# config/runtime.exs
import Config

env = MyApp.Env.load!()

config :my_app, MyApp.Repo, url: env.database_url
config :my_app, :pricing, env.pricing.data   # %{currency: "EUR", tiers: [...]}

config :my_app, MyAppWeb.Endpoint,
  http: [port: env.port],
  https: [certfile: env.serving_tls.data.certfile, keyfile: env.serving_tls.data.keyfile]
```

A bad environment stops the boot with every problem listed:

```
** (Docuconf.ValidationError) docuconf: 3 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
  - serving-tls [certificate_expiring]: certificate expires at 2026-10-20T09:00:00Z (379h12m5s left), less than minRemaining 720h
```

Export the contract in CI, and commit it or publish it next to the image:

```sh
mix docuconf.export MyApp.Env              # writes contract.cue
mix docuconf.export MyApp.Env --check      # fails if contract.cue is stale
```

You can also set the module once in `mix.exs` (`docuconf: [module: MyApp.Env]`)
and run plain `mix docuconf.export`. [`examples/orders`](examples/orders) is a complete app.

## Declaring variables

`env field, type, opts` declares a variable. Its name is the field upcased
(`:database_url` reads `DATABASE_URL`), or `name: "..."` sets it. `secret`
is `env` with `secret: true`. The module gets a struct with one field per
input, and `load/1`, `load!/1` and `export/1`.

| Type | Contract type | Value | Options |
|---|---|---|---|
| `:string` | `string` | `String.t()` | `min_length`, `max_length`, `pattern` |
| `:integer` | `int` | 64-bit integer | `min`, `max` |
| `:float` | `float` | float (`NaN`/`Inf` rejected) | `min`, `max` |
| `:boolean` | `bool` | `true`/`false`, case-insensitive | |
| `:duration` | `duration` (`go` encoding) | integer in `unit` | `min`, `max`, `unit` |
| `:url` | `url` | string with `scheme://` | `schemes` |
| `{:in, values}` | `enum` | string | |
| `{:list, :string}`, `{:list, :integer}` | `list` (`csv` encoding) | list | `separator` (default `,`), `min_items`, `max_items` |
| `:json` | `json` | decoded JSON | `schema` |

Every variable takes `description` (or `doc`; at least 5 characters, required),
`required`, `default`, `secret`, `group`, `examples`, `deprecated`
(a message, or `[message: ..., replaced_by: "NEW_NAME"]`) and `config_key`.

- **Durations** use Go syntax (`1m30s`, `250ms`, `1.5h`), parsed by docuconf
  itself because Elixir has no standard duration string, and written to the
  contract in canonical Go form. `unit:` picks what the app gets:
  `:millisecond` (the default, matching OTP timeouts), `:second`,
  `:microsecond`, `:nanosecond`, or `:duration` for an Elixir `Duration`.
  A value that is not a whole number of the unit is rejected.
- **Patterns** are RE2 and match anywhere in the value, as in CUE; anchor
  them with `^` and `$`. A `~r` sigil or a string both work. PCRE-only
  features (lookaround, backreferences, atomic groups, possessive
  quantifiers) are rejected at compile time. Matching follows RE2, not
  PCRE: `$` means end of text (not "before a final newline"), and `\d`,
  `\w`, `\s` and `\b` are ASCII-only.
- **Empty strings** are present values for `:string` and unset for every
  other type. Values are never trimmed.
- **JSON schemas** are a JSON Schema map, or a keyword spec in the
  NimbleOptions style (`[per_minute: [type: :pos_integer, required: true]]`),
  from which docuconf generates the schema. A value checked against a
  keyword spec is bound to it, so its keys become the spec's atoms.

The declaration is checked when the module compiles: name format,
description length, defaults against their own constraints, required or
secret with a default, RE2-only patterns, unknown options and file mount
rules. Every problem is listed in one `Docuconf.DeclarationError`. Names
that look like feature flags (`FF_`, `FEATURE_`, `ENABLE_`) get a compile
warning (SPEC §10); `flag_warning: false` silences it for a deploy-time switch.

## Declaring files

| Macro | Contract type | `data` after loading | Extra options |
|---|---|---|---|
| `config_file` | `config` | decoded document (atoms with a keyword spec) | `format` (`:json`, `:yaml`, `:toml`), `schema`, `decoder` |
| `tls_file` | `tls` | `%{certfile, keyfile, cacertfile, certificate, chain, cacerts, not_after}` | `dns_names`, `key_algorithms` (`:rsa`, `:ecdsa`, `:ed25519`), `min_remaining`, `require_ca` |
| `ca_bundle_file` | `caBundle` | list of DER certificates (for `cacerts:`) | `min_certificates` |
| `keystore_file` | `keystore` | `nil` | `format` (`:pkcs12`, `:jks`), `password_var` |
| `text_file` | `text` | the content | `pattern`, `min_length`, `max_length` |
| `binary_file` | `binary` | `nil` | |

All take `description`, `path` (absolute), `path_env`, `required`, `secret`,
`reload` (`:restart` or `:watch`), `max_size`, `group` and `deprecated`. The
input name is the field with `_` replaced by `-` (`:serving_tls` is
`serving-tls`). A loaded file is a `%Docuconf.LoadedFile{path, data}`; an
absent optional file is `nil`.

- **YAML and TOML.** Elixir has no built-in parser, so these need a
  `decoder:` such as `&YamlElixir.read_from_string/1` or `&Toml.decode/1`
  (a remote capture returning `{:ok, data}`). JSON needs nothing.
- **TLS** checks use `:public_key`: the key matches the certificate (by
  signing and verifying a probe), the certificate is valid now with at least
  `min_remaining` left, `:public_key.pkix_verify_hostname/3` covers every
  name in `dns_names` (a wildcard covers one label), the key algorithm is
  allowed, and with `require_ca` the chain in `tls.crt` validates against
  `ca.crt` with `:public_key.pkix_path_validation/3`.
- **Keystores.** OTP cannot read PKCS#12, so docuconf parses the PFX
  structure and verifies its integrity MAC with the password from
  `password_var`. SHA-1 and SHA-2 MACs are supported. A matching MAC proves
  the password is right and the file is intact; the keys are not decrypted.
  JKS and JCEKS stores are checked the same way. PBMAC1 MACs (OpenSSL 3.4
  `-pbmac1_pbkdf2`) are not supported yet.
- `DOCUCONF_FILE_ROOT` is prefixed to every absolute path, including paths
  read from a `path_env` variable, for local development and tests.

### Reloading files

`reload: :watch` puts a promise in the contract: the app rereads the file
itself, so the platform does not restart the pod when it changes. Keep it by
running `Docuconf.Watcher` in your supervision tree:

```elixir
children = [
  {Docuconf.Watcher,
   module: MyApp.Env,
   on_change: fn :pricing, file -> MyApp.Pricing.put(file.data) end}
]
```

It polls (OTP has no portable file-event API), runs the file's boot checks
again on every change, and calls `on_change` only for valid content. If you
do not run it, declare `reload: :restart`, which is the default.

The promise is enforced. Supervision is decided at runtime, so it cannot be
checked when the declaration compiles; instead `load!/1`, when the
declaration has a `watch` input, checks once the application that owns the
module has started (its supervision tree is up by then) that a
`Docuconf.Watcher` for the module is running. If not, it prints the problem,
writes it to the termination log and **stops the node** with exit status 1,
so the pod fails like any other bad configuration rather than silently
serving stale files:

```
docuconf: MyApp.Env declares reload: watch for pricing, but no Docuconf.Watcher is running for it. ...
```

Pass `watcher_check: :warn` to only log it (for example when the watcher
lives in another application that starts later), or `watcher_check: false`
to skip it. Loads with an explicit `env:` map (tests) skip the check unless
`watcher_check` is given. A module that belongs to no application (a script)
is checked after `watcher_grace` milliseconds (default 5000). With
`reboot_system_after_config: true` in a release, the check does not survive
the reboot.

## Loading

`MyApp.Env.load!(opts)` returns the struct or raises
`Docuconf.ValidationError` (`load/1` returns `{:ok, env}` or
`{:error, error}`). Options:

- `env:` a map to read instead of the process environment (tests);
- `dotenv: ".env"` reads a `.env` file first, for development. Real
  environment variables always override it;
- `file_root:`, `termination_log:` (a path, or `false`), `now:` (a
  `DateTime` for certificate checks), `warn: false`;
- `watcher_check:` and `watcher_grace:` (see [Reloading files](#reloading-files)).

Warnings go to standard error: a deprecated variable that is set, and a
secret that ends in a newline (a common `kubectl create secret --from-file`
mistake).

### Tests and build-time tasks

`runtime.exs` runs for `mix test` too. Either load only outside tests:

```elixir
if config_env() != :test do
  env = MyApp.Env.load!()
  # ...
end
```

or load in tests with an explicit environment: `MyApp.Env.load!(env: %{...})`.
`mix docuconf.export` never needs the environment.

## Injected secrets

Platforms often inject secrets into the environment at runtime: Bank-Vaults'
vault-env resolves `vault:` references, `op run` resolves `op://`, and vals
resolves `ref+`. docuconf reads the environment as the process sees it after
injection, so injected values are validated like any other, and it never
resolves a reference itself (SPEC §4.5.1). If the injector did not run, a
secret variable still holds the reference; docuconf reports that as
`invalid_type`, naming the scheme but never the value:

```
  - DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

## Config-file overlays

There is no overlay API (SPEC §4.7). Elixir's `config/*.exs` files are
compiled into the release and `config/runtime.exs` is code, not a layered
file stack, so there is nowhere to put a platform-mounted overlay between
the app's files and the environment. A declaration cannot carry `overlays`,
and the exported contract never has any. Mount a `config_file` input
instead if the platform needs to supply structured configuration.

## Error codes

`missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`,
`not_in_enum`, `invalid_scheme`, `too_few_items`, `too_many_items`,
`file_missing`, `file_unreadable`, `file_too_large`, `file_malformed`,
`schema_mismatch`, `certificate_invalid`, `certificate_expiring`,
`certificate_name_mismatch`, `key_mismatch`, `keystore_unreadable`
(SPEC §11.2). Each `Docuconf.Violation` has `input`, `kind`, `code` and `message`.

## Not covered yet

- Profiles (SPEC §4.4). Elixir's `config/*.exs` files are compiled into the
  release, so a value there is an ordinary `default:`. There is no runtime
  profile selector to export.
- `list` encodings other than `csv`, and duration encodings other than `go`.
  These are the encodings this SDK parses, and the contract records them.
- The contract-first mode (loading a `contract.cue` with no declaration),
  Markdown docs generation and `deprecated.replaced_by` fallback reads.

## Development

```sh
mix test
```

The export test vets the generated contract with `cue vet -c` against the
meta-schema from [docuconf-go](https://github.com/docuconf/docuconf-go)
(`spec/cue`). Point `DOCUCONF_SPEC_CUE` at that directory (a sibling checkout
is found automatically). The test is skipped when `cue` is missing, unless
`DOCUCONF_REQUIRE_VET=1`. Install cue with
`go install cuelang.org/go/cmd/cue@v0.17.1`. Regenerate the golden file with
`UPDATE_GOLDEN=1 mix test`.

## Licence

The licence has not been chosen yet, so this repository has no LICENSE file.
Do not publish the package until one is added (see [RELEASING.md](RELEASING.md)).
