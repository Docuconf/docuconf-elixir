# docuconf for Elixir

Typed configuration contracts for Elixir applications, from the
[docuconf specification](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md) (v1alpha1).

Elixir apps read their runtime configuration in `config/runtime.exs` with
`System.fetch_env!/1` and `System.get_env/2`. docuconf keeps that file and
adds what it lacks:

- one declaration of every environment variable and file the app reads, with
  types, constraints, descriptions and secrets;
- validation at boot, with **every** problem reported together under a
  stable error code, secret values never printed (not in errors, and not
  when the loaded struct is inspected or logged), and the report also
  written to `/dev/termination-log` so `kubectl describe pod` shows it;
- boot checks for files: JSON/YAML/TOML config against a JSON Schema, TLS
  key pairs, CA bundles, PKCS#12/JKS keystores, text and binary files;
- `mix docuconf.export`, which writes `contract.cue`, a CUE document the
  platform validates before it deploys anything.

There are no runtime dependencies. JSON comes from Elixir 1.18's `JSON`
module and certificate handling from OTP's `:public_key`.
[`examples/orders`](examples/orders) is a small HTTP service built with it.

The quickstart below goes install, declare, run, see an error, test, export,
deploy. [Phoenix](#phoenix) has a drop-in `runtime.exs`, and the
[reference](#reference) follows.

## 1. Install

docuconf is not on Hex yet. Until the first release, depend on it from
GitHub in `mix.exs`:

<!-- snippet: install -->
```elixir
def deps do
  [
    {:docuconf, github: "docuconf/docuconf-elixir", branch: "main"}
  ]
end
```

then run `mix deps.get`. A local checkout works the same way with
`{:docuconf, path: "../docuconf-elixir"}`. Once 0.1.0 is published the
dependency becomes `{:docuconf, "~> 0.1"}`.

Requires Elixir 1.18 or later, on OTP 25 or later.

## 2. Declare

One module lists everything the app reads from its environment:

<!-- snippet: quickstart-env -->
```elixir
defmodule MyApp.Env do
  use Docuconf, name: "my-app"

  env :port, :pos_integer, description: "HTTP listen port", default: 4000, max: 65535

  env :log_level, {:in, [:debug, :info, :warning, :error]},
    description: "Minimum log level",
    default: :info

  env :request_timeout, :duration, description: "Upstream request timeout", default: "30s"

  secret :database_url, :url,
    description: "Primary Postgres connection string",
    required: true,
    schemes: ["postgres", "ecto"]
end
```

The name of each variable is its field upcased (`:database_url` reads
`DATABASE_URL`). The declaration is checked when the module compiles: an
unknown option, a default that breaks its own constraints or a pattern RE2
cannot run is a compile error that points at the line, with a suggestion
(`unknown option :maximum for :integer; did you mean :max?`).

The module gets a struct with a typed field per input (`@type t`, so
Dialyzer and your editor know `log_level` is `:debug | :info | ...`),
generated docs listing every variable, and `load/1`, `load!/1` and
`export/1`.

## 3. Run

Load it in `config/runtime.exs`:

<!-- snippet: quickstart-runtime -->
```elixir
import Config

if config_env() != :test do
  env = MyApp.Env.load!(dotenv: config_env() == :dev && ".env")

  config :logger, level: env.log_level
  config :my_app, MyApp.Repo, url: env.database_url
  config :my_app, :request_timeout, env.request_timeout
end
```

`env.log_level` is an atom, `env.request_timeout` is `30_000` (milliseconds,
ready for OTP timeouts) and `env.port` an integer. In development, put
values in a `.env` file (`DATABASE_URL=postgres://localhost/my_app_dev`);
real environment variables override it, and outside `:dev` the expression
is `false`, so no file is read. Tests load the declaration themselves (see
[step 5](#5-test)).

`inspect(env)` (and so IEx, Logger and crash reports) shows
`database_url: **redacted**`. Storing the struct with
`config :my_app, env: env` is fine for inspection, but remember that
anything in the application environment can be read with
`Application.get_env/2`.

## 4. See an error

A bad environment stops the boot with every problem listed, and nothing
else:

```sh
PORT=0 mix run
```

<!-- snippet: quickstart-error -->
```text
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, but not set
  - PORT [out_of_range]: "0" is below min 1
```

The process exits with status 1, with no stack trace and, in a release, no
`erl_crash.dump`. The same lines go to `/dev/termination-log` inside a
container. Secret values never appear: a wrong `DATABASE_URL` shows its
scheme (`scheme "mysql" is not one of postgres, ecto`), never the URL.

Typos get a hint. If `DATABSE_URL` is set, boot also prints
`docuconf: warning: DATABSE_URL is set but not declared; did you mean DATABASE_URL?`
(a warning, never the value).

## 5. Test

`load/1` and `load!/1` take an explicit environment with `env:`, so a test
never reads or changes the process environment. With `env:`, `load!/1`
raises `Docuconf.ValidationError` instead of stopping the node, and no
termination log is written.

<!-- snippet: quickstart-test -->
```elixir
# test/my_app/env_test.exs
defmodule MyApp.EnvTest do
  use ExUnit.Case, async: true

  @valid %{"DATABASE_URL" => "postgres://app:secret@localhost/app"}

  test "defaults apply" do
    env = MyApp.Env.load!(env: @valid)
    assert env.port == 4000
    assert env.log_level == :info
    assert env.request_timeout == 30_000
  end

  test "every problem is reported together" do
    assert {:error, error} = MyApp.Env.load(env: %{"PORT" => "0"})

    assert Enum.map(error.violations, &{&1.input, &1.code}) == [
             {"DATABASE_URL", :missing_required},
             {"PORT", :out_of_range}
           ]
  end

  test "secrets are not shown" do
    env = MyApp.Env.load!(env: @valid)
    refute inspect(env) =~ "secret@"
  end
end
```

File inputs are read under `file_root:` (`MyApp.Env.load!(env: ..., file_root: tmp_dir)`),
so tests can lay out `/etc/...` mounts in a temporary directory.

## 6. Export

Export the contract and commit it, or publish it next to the image:

```sh
mix docuconf.export MyApp.Env              # writes contract.cue
mix docuconf.export MyApp.Env --check      # in CI: fails if contract.cue is stale
mix docuconf.export MyApp.Env -o -         # to stdout, nothing else
```

In a fresh CI job, run `mix deps.compile` before `-o -`: Mix compiles
docuconf itself, and says so on stdout, before the task exists to silence it.

Export never needs the environment. Set the module once in `mix.exs`
(`docuconf: [module: MyApp.Env]`) to run plain `mix docuconf.export`.
`--check` prints the difference and the exact command that fixes it, and
ignores `appVersion` and the SDK version, so bumping `version` in `mix.exs`
does not fail CI.

## 7. Deploy

Ship `contract.cue` with the image. The platform validates its values
against it before anything runs: `docuconf vet` checks a deployment's values
and `docuconf render` turns them into the Kubernetes env and Secret
references, or a Helm-based platform uses the
[docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm/docuconf).
A missing `DATABASE_URL` is then caught at deploy time, and the boot check
is the last line of defence. In a release, `runtime.exs` runs at boot, so
the same clean failure and termination log apply.

## Phoenix

A Phoenix app generated by `mix phx.new` reads its environment in
`config/runtime.exs`, inside `if config_env() == :prod`. Declare the same
variables:

<!-- snippet: phoenix-env -->
```elixir
defmodule MyApp.Env do
  use Docuconf, name: "my-app"

  env :phx_server, :boolean,
    description: "Start the endpoint (set to true by rel/overlays/bin/server)",
    default: false

  env :phx_host, :string, description: "Host name in generated URLs", default: "example.com"
  env :port, :pos_integer, description: "HTTP listen port", default: 4000, max: 65535

  secret :secret_key_base, :string,
    description: "Cookie signing key (mix phx.gen.secret)",
    required: true,
    min_length: 64

  secret :database_url, :url,
    description: "Ecto database URL",
    required: true,
    schemes: ["ecto", "postgres", "postgresql"]

  env :pool_size, :pos_integer, description: "Database connection pool size", default: 10
  env :ecto_ipv6, :boolean, description: "Connect to the database over IPv6", default: false
  env :dns_cluster_query, :string, description: "DNS query that finds the other nodes"
end
```

and replace the generated `runtime.exs` with:

<!-- snippet: phoenix-runtime -->
```elixir
import Config

if config_env() != :test do
  # In dev, values that do not belong in the contract (a dev cookie key, the
  # local database) come from fallback_env; real variables win.
  env =
    MyApp.Env.load!(
      fallback_env:
        config_env() == :dev &&
          %{
            "SECRET_KEY_BASE" => String.duplicate("dev-only-key-", 5),
            "DATABASE_URL" => "ecto://postgres:postgres@localhost/my_app_dev"
          }
    )

  if env.phx_server do
    config :my_app, MyAppWeb.Endpoint, server: true
  end

  config :my_app, MyApp.Repo,
    url: env.database_url,
    pool_size: env.pool_size,
    socket_options: if(env.ecto_ipv6, do: [:inet6], else: [])

  config :my_app, MyAppWeb.Endpoint,
    http: [port: env.port],
    secret_key_base: env.secret_key_base

  config :my_app, :dns_cluster_query, env.dns_cluster_query

  if config_env() == :prod do
    config :my_app, MyAppWeb.Endpoint,
      url: [host: env.phx_host, port: 443, scheme: "https"],
      http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}]
  end
end
```

Now `mix phx.server` validates in dev too, with no `.env` needed (add
`dotenv: config_env() == :dev && ".env"` if you keep local values in one),
and a
release with a bad environment fails at boot with the problem list.
`config/dev.exs` keeps its other settings; `http: [port: ...]` merges with
its `ip:`. Two differences from the generator's code:

- `PHX_SERVER` is a boolean: `true` or `false` (the generated
  `bin/server` sets `PHX_SERVER=true`). `PHX_SERVER=1` is rejected as
  `"1" is not true or false`, where the generator accepted any value.
- Tests skip `runtime.exs` (`config/test.exs` already has everything) and
  load the declaration with `env:` as in [step 5](#5-test).

Run `mix docuconf.export` in CI as in [step 6](#6-export). This is a
recipe rather than a Phoenix-specific module: everything happens in
`runtime.exs`, which Phoenix already owns, and the recipe is run in this
repository's tests (`test/readme_test.exs`) for dev, prod and the
`PHX_SERVER` switch.

## Reference

### Declaring variables

`env field, type, opts` declares a variable. `secret` is `env` with
`secret: true`.

| Type | Contract type | Value | Options |
|---|---|---|---|
| `:string` | `string` | `String.t()` | `min_length`, `max_length`, `pattern` |
| `:integer` | `int` | 64-bit integer | `min`, `max` |
| `:pos_integer`, `:non_neg_integer` | `int` | integer, `min: 1` or `min: 0` | `min`, `max` |
| `:float` | `float` | float (`NaN`/`Inf` rejected) | `min`, `max` |
| `:boolean` | `bool` | `true`/`false`, case-insensitive | |
| `:duration` | `duration` | integer in `unit` | `min`, `max`, `unit`, `encoding` |
| `:url` | `url` | string with `scheme://` | `schemes`, `max_length` |
| `{:in, values}` | `enum` | an atom if every value is an atom, else a string | |
| `{:list, :string}`, `{:list, :integer}` | `list` | list | `encoding`, `separator` (default `,`), `min_items`, `max_items`; `item_min`, `item_max` (integer lists); `item_min_length`, `item_max_length` (string lists) |
| `:json` | `json` | decoded JSON | `schema`, `max_length` |

Every variable takes `description` (or `doc`; at least 5 characters, required
unless an `@doc` gives it), `details` (see below), `required`, `default`, `secret`, `group`, `examples`, `deprecated`
(a message, or `[message: ..., replaced_by: "NEW_NAME"]`), `config_key`,
`name` and `flag_warning`.

- **Durations** use Go syntax in the environment by default (`1m30s`,
  `250ms`, `1.5h`), parsed by docuconf itself because Elixir has no
  standard duration string, and are written to the contract in canonical Go
  form. `unit:` picks what the app gets: `:millisecond` (the default,
  matching OTP timeouts), `:second`, `:microsecond`, `:nanosecond`, or
  `:duration` for an Elixir `Duration`. A value that is not a whole number
  of the unit is rejected. `default`, `min` and `max` take a Go string
  (`"30s"`), the variable's own encoding (`"PT30S"` with `encoding: :iso8601`),
  an integer in the unit (`30_000`, `:timer.seconds(30)`) or an Elixir
  `Duration` (`Duration.new!(second: 30)`).
- **Encodings** (SPEC §5) say how the platform writes a list or duration
  into the environment. Lists: `:csv` (the default, joined by `separator`),
  `:json` (`["a","b"]`) or `:indexed` (`NAME__0`, `NAME__1`, ...; items
  must be numbered from 0 with no gap, or the list is `invalid_type`).
  Durations: `:go` (the default), `:iso8601` (`PT1M30S`), `:seconds` (`90`)
  or `:timespan` (`00:01:30`). A value in the wrong form gets the right one
  in its error: `"30s" is not an ISO 8601 duration such as PT1M30S; write PT30S`.
- **Patterns** are RE2 and match anywhere in the value, as in CUE; anchor
  them with `^` and `$`. A `~r` sigil or a string both work. PCRE-only
  features (lookaround, backreferences, atomic groups, possessive
  quantifiers) are rejected at compile time. Matching follows RE2, not
  PCRE: `$` means end of text (not "before a final newline"), and `\d`,
  `\w`, `\s` and `\b` are ASCII-only.
- **Item bounds**: `item_min` and `item_max` bound each item of a
  `{:list, :integer}` and are exported as `itemMin` and `itemMax`. Every
  item is already checked against the 64-bit range of the contract's `int`.
- **Lengths** count characters, meaning Unicode code points
  (`String.to_charlist/1`), never bytes or graphemes: `"日本"` is 2 and
  `"ZÜ01"` fits `item_max_length: 4`. `max_length` on a `:url` bounds the
  string as it is; on a `:json` it bounds the wire string, the raw value as
  received (whitespace included), or the compact JSON for a default.
  `item_min_length` and `item_max_length` bound each item of a
  `{:list, :string}` after it is split, so separators never count, and are
  exported as `itemMinLength` and `itemMaxLength`. A value outside a length
  limit is `out_of_range`; a secret reports its length, never its value.
- **Empty strings** are present values for `:string` and unset for every
  other type. Values are never trimmed.
- **JSON schemas** are a JSON Schema map, or a keyword spec in the
  NimbleOptions style (`[per_minute: [type: :pos_integer, required: true]]`),
  from which docuconf generates the schema. A value checked against a
  keyword spec is bound to it, so its keys become the spec's atoms.

The declaration is checked when the module compiles: name format,
description length, defaults against their own constraints, required or
secret with a default, RE2-only patterns, unknown or misplaced options,
non-boolean `required`/`secret`, and file mount rules. Every problem is
listed in one `Docuconf.DeclarationError`, each with its `file:line`.
Calling `env` in a module without `use Docuconf` is a compile error. Names
that look like feature flags (`FF_`, `FEATURE_`, `ENABLE_`) get a compile
warning on their line (SPEC §10); `flag_warning: false` on that declaration
silences it for a deploy-time switch.

### Descriptions and details

Document an input with `@doc`, as you would a function. Its first paragraph
is the contract's `description` (on one line, without the final period) and
the rest is `details`: Markdown for generated docs, at most 4000 characters,
never read at runtime.

```elixir
defmodule MyApp.DocumentedEnv do
  use Docuconf, name: "my-app"

  @doc """
  Upstream request timeout.

  Raise it for clients that upload large batches. Keep it below the load
  balancer's idle timeout, or the client sees a reset rather than a `504`.
  """
  env :request_timeout, :duration, default: "30s"

  env :pool_size, :pos_integer,
    description: "Database connection pool size",
    details: "One connection per scheduler is a good start.",
    default: 10
end
```

The `description:` and `details:` options set either one explicitly and win
over the `@doc`, which `env`, `secret` and the file declarations consume, so
it never documents the next function. ExDoc-only syntax becomes CommonMark:
auto-link prefixes (`` `m:Mod` ``, `` `t:Mod.t/0` ``) are dropped,
``[text](`Mod.fun/1`)`` links become code spans and `{: .info}` attributes are
removed. A missing or short description, and details that are blank or longer
than 4000 characters, fail compilation. `docuconf docs` in the
[docuconf CLI](https://github.com/docuconf/docuconf-go) generates `CONFIG.md`
and `CONFIG.agents.md` from the exported contract.

### Declaring files

| Macro | Contract type | `data` after loading | Extra options |
|---|---|---|---|
| `config_file` | `config` | decoded document (atoms with a keyword spec) | `format` (`:json`, `:yaml`, `:toml`), `schema`, `decoder` |
| `tls_file` | `tls` | `%{certfile, keyfile, cacertfile, certificate, chain, cacerts, not_after}` | `dns_names`, `key_algorithms` (`:rsa`, `:ecdsa`, `:ed25519`), `min_remaining`, `require_ca` |
| `ca_bundle_file` | `caBundle` | list of DER certificates (for `cacerts:`) | `min_certificates` |
| `keystore_file` | `keystore` | `nil` | `format` (`:pkcs12`, `:jks`), `password_var` |
| `text_file` | `text` | the content | `pattern`, `min_length`, `max_length` |
| `binary_file` | `binary` | `nil` | |

```elixir
defmodule MyApp.Files do
  use Docuconf, name: "orders"

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

All take `description` (or an `@doc`, as for variables), `details`, `path`
(absolute), `path_env`, `required`, `secret`, `reload` (`:restart` or
`:watch`), `max_size`, `group` and `deprecated`. The
input name is the field with `_` replaced by `-` (`:serving_tls` is
`serving-tls`). A loaded file is a `%Docuconf.LoadedFile{path, data}`; an
absent optional file is `nil`. A secret `config` or `text` file's `data` is
shown as `**redacted**` when inspected.

- **Local paths.** `DOCUCONF_FILE_ROOT` (or `file_root:`) is prefixed to
  every absolute path, including paths read from a `path_env` variable, for
  local development and tests. A missing file's error says so.
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

### Reloading files

`reload: :watch` puts a promise in the contract: the app rereads the file
itself, so the platform does not restart the pod when it changes. Keep it by
running `Docuconf.Watcher` in your supervision tree:

```elixir
children = [
  {Docuconf.Watcher,
   module: MyApp.Files,
   on_change: fn :pricing, file -> Application.put_env(:my_app, :pricing, file.data) end}
]
```

It polls (OTP has no portable file-event API), runs the file's boot checks
again on every change, and calls `on_change` only for valid content. It
reads the environment the way the module's last `load` did, `.env` and
`file_root` included. If you do not run it, declare `reload: :restart`,
which is the default.

The promise is enforced. `load!/1`, when the declaration has a `watch`
input, checks once the application that owns the module has started that a
`Docuconf.Watcher` for the module is running. If not, it prints the problem
once, writes it to the termination log and **stops the node** with exit
status 1. Pass `watcher_check: :warn` to only log it, or
`watcher_check: false` to skip it. Loads with an explicit `env:` map skip
the check unless `watcher_check` is given. A module that belongs to no
application (a script) is checked after `watcher_grace` milliseconds
(default 5000).

### Loading

`MyApp.Env.load(opts)` returns `{:ok, env}` or `{:error, %Docuconf.ValidationError{}}`.
`MyApp.Env.load!(opts)` returns the struct; on failure, reading the process
environment, it prints the problems and stops the node with exit status 1
(`on_error: :halt`), and with `env:` it raises (`on_error: :raise`). Options:

- `env:` a map to read instead of the process environment (tests);
- `dotenv:` a `.env` file to read first, for development; real environment
  variables override it. `nil` or `false` reads none. A named file that
  does not exist is a warning;
- `fallback_env:` a map used only for variables nothing else sets (dev-only
  values); `nil` or `false` uses none;
- `file_root:`, `termination_log:` (a path, or `false`), `now:` (a
  `DateTime` for certificate checks), `warn: false`;
- `on_error:` `:halt` or `:raise`, for `load!/1`;
- `watcher_check:` and `watcher_grace:` (see [Reloading files](#reloading-files)).

Warnings go to standard error: a deprecated variable that is set, a secret
that ends in a newline (a common `kubectl create secret --from-file`
mistake), a missing `.env` file, and a set variable whose name is a likely
typo of a declared one.

### Injected secrets

Platforms often inject secrets into the environment at runtime: Bank-Vaults'
vault-env resolves `vault:` references, `op run` resolves `op://`, and vals
resolves `ref+`. docuconf reads the environment as the process sees it after
injection, so injected values are validated like any other, and it never
resolves a reference itself (SPEC §4.5.1). If the injector did not run, a
secret variable still holds the reference; docuconf reports that as
`invalid_type`, naming the scheme but never the value:

```text
  - DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

### Config-file overlays

There is no overlay API (SPEC §4.7). Elixir's `config/*.exs` files are
compiled into the release and `config/runtime.exs` is code, not a layered
file stack, so there is nowhere to put a platform-mounted overlay between
the app's files and the environment. A declaration cannot carry `overlays`,
and the exported contract never has any. Mount a `config_file` input
instead if the platform needs to supply structured configuration.

### Error codes

`missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`,
`not_in_enum`, `invalid_scheme`, `too_few_items`, `too_many_items`,
`file_missing`, `file_unreadable`, `file_too_large`, `file_malformed`,
`schema_mismatch`, `certificate_invalid`, `certificate_expiring`,
`certificate_name_mismatch`, `key_mismatch`, `keystore_unreadable`
(SPEC §11.2). Each `Docuconf.Violation` has `input`, `kind`, `code` and `message`.

### Contract-first mode

`Docuconf.Contract` validates an environment against a contract given as
JSON (`cue export contract.cue --out json`), with no `use Docuconf` module,
for teams that write their contract in CUE by hand (SPEC §11.2 item 11):

```elixir
contract = %{
  "apiVersion" => "docuconf.dev/v1alpha1",
  "kind" => "ConfigContract",
  "metadata" => %{"name" => "orders"},
  "vars" => %{"PORT" => %{"type" => "int", "description" => "HTTP listen port", "default" => 8080}}
}

{:ok, values} = Docuconf.Contract.load(contract, env: %{})
8080 = values["PORT"]
```

The contract is turned into the same declaration the DSL builds, so it gets
the same checks and parsers. Values come back as a
`Docuconf.Contract.Values`, keyed by variable or file input name: read them
with `values["PORT"]`, or call `Docuconf.Contract.Values.to_map/1`.
Inspecting it redacts secrets. Durations are integers in `duration_unit:`
(`:millisecond` by default, as in the DSL). Every list and duration
encoding is parsed. It rejects `reload: "watch"` (it starts no watcher),
`overlays` and `profiles`; a `yaml` or `toml` config file needs
`decoders: %{"yaml" => &YamlElixir.read_from_string/1}`.

### Conformance

`test/conformance_test.exs` runs the shared conformance suite (SPEC §12,
`conformance/cases.json` in docuconf-go) through contract-first mode, one
ExUnit test per case, named by the case `id`:

```sh
DOCUCONF_CONFORMANCE=../docuconf-go/conformance/cases.json \
DOCUCONF_REQUIRE_CONFORMANCE=1 mix test test/conformance_test.exs
```

Without `DOCUCONF_CONFORMANCE` the runner reads
`../docuconf-go/conformance/cases.json`, and skips when it is missing unless
`DOCUCONF_REQUIRE_CONFORMANCE=1`. CI sets both, using its docuconf-go
checkout. No capability tags are skipped: Elixir integers hold every 64-bit
value (`int64`), and `json` values are validated against their JSON Schema
(`json-schema`).

### Not covered yet

- Profiles (SPEC §4.4). Elixir's `config/*.exs` files are compiled into the
  release, so a value there is an ordinary `default:`. There is no runtime
  profile selector to export.
- Markdown docs generation and `deprecated.replaced_by` fallback reads.

## Development

```sh
mix test
```

`test/readme_test.exs` compiles every Elixir block in this README, and runs
the quickstart, its test and the Phoenix recipe in a fresh VM. The export
test vets the generated contract with `cue vet -c` against the meta-schema
from [docuconf-go](https://github.com/docuconf/docuconf-go) (`spec/cue`).
Point `DOCUCONF_SPEC_CUE` at that directory (a sibling checkout is found
automatically). The test is skipped when `cue` is missing, unless
`DOCUCONF_REQUIRE_VET=1`. Install cue with
`go install cuelang.org/go/cmd/cue@v0.17.1`. Regenerate the golden file with
`UPDATE_GOLDEN=1 mix test`.

## Licence

MIT. See [LICENSE](LICENSE).
