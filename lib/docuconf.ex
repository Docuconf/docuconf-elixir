defmodule Docuconf do
  @moduledoc """
  Typed configuration contracts for Elixir applications.

  Elixir apps read runtime configuration in `config/runtime.exs` with
  `System.get_env/1` and friends. docuconf keeps that idiom and adds what it
  lacks: one declaration, in the NimbleOptions style, of every environment
  variable and file the app reads, with types, constraints, descriptions and
  secrets; validation of all of them at boot with every problem reported
  together; and an exported `contract.cue` the platform validates before
  deploying.

      defmodule MyApp.Env do
        use Docuconf, name: "orders-api"

        env :port, :integer, description: "HTTP listen port", default: 4000, min: 1, max: 65535
        secret :database_url, :url, description: "Primary Postgres connection string",
          required: true, schemes: ["postgres", "ecto"]
        env :request_timeout, :duration, description: "Upstream request timeout", default: "30s"

        tls_file :serving_tls, description: "Certificate the API serves HTTPS with",
          path: "/etc/orders/tls", dns_names: ["orders.internal"], min_remaining: "720h"
      end

      # config/runtime.exs
      import Config
      env = MyApp.Env.load!()
      config :my_app, MyApp.Repo, url: env.database_url
      config :my_app, MyAppWeb.Endpoint, http: [port: env.port]

  See the README for every option.
  """

  alias Docuconf.{Declaration, Loader, ValidationError}

  @doc false
  defmacro __using__(opts) do
    quote do
      import Docuconf,
        only: [
          env: 2,
          env: 3,
          secret: 2,
          secret: 3,
          config_file: 2,
          tls_file: 2,
          ca_bundle_file: 2,
          keystore_file: 2,
          text_file: 2,
          binary_file: 2
        ]

      Module.register_attribute(__MODULE__, :docuconf_vars, accumulate: true)
      Module.register_attribute(__MODULE__, :docuconf_files, accumulate: true)
      @docuconf_opts unquote(opts)
      @before_compile Docuconf
    end
  end

  @doc """
  Declares an environment variable. The name is the field upcased
  (`:database_url` reads `DATABASE_URL`) unless `name:` is given.

  Types: `:string`, `:integer`, `:float`, `:boolean`, `:duration` (Go
  syntax, `1m30s`), `:url`, `{:in, values}` (or `:enum` with `values:`),
  `{:list, :string}`, `{:list, :integer}` (comma-separated, or `separator:`)
  and `:json`.

  Options: `description` (or `doc`, at least 5 characters, required),
  `required`, `default`, `secret`, `group`, `examples`, `deprecated`,
  `config_key`, `name`, `flag_warning`; by type, `min`/`max` (integer,
  float, duration), `min_length`/`max_length`/`pattern` (string; RE2,
  partial match), `schemes` (url), `values` (enum), `min_items`/`max_items`/
  `separator` (list), `schema` (json: a JSON Schema map or a keyword spec),
  `unit` (duration: `:millisecond` by default, `:second`, `:microsecond`,
  `:nanosecond` or `:duration` for an Elixir `Duration`).
  """
  defmacro env(field, type, opts \\ []) do
    quote do
      @docuconf_vars {unquote(field), unquote(type), unquote(opts)}
    end
  end

  @doc "Declares a secret environment variable: `env` with `secret: true`."
  defmacro secret(field, type, opts \\ []) do
    quote do
      @docuconf_vars {unquote(field), unquote(type), Keyword.put(unquote(opts), :secret, true)}
    end
  end

  @file_doc """
  Common options: `description` (required), `path` (absolute; required),
  `path_env`, `required`, `secret`, `reload` (`:restart` or `:watch`; see
  `Docuconf.Watcher`), `max_size` (bytes), `group`, `deprecated`, `name`
  (the input name; defaults to the field with `_` replaced by `-`).
  """

  @doc """
  Declares a structured config file. Extra options: `format` (`:json`,
  `:yaml` or `:toml`), `schema` (a JSON Schema map, or a keyword spec the
  file is bound to), `decoder` (`&Mod.fun/1` returning `{:ok, data}`;
  required for YAML and TOML, since Elixir has no built-in parser for them).

  #{@file_doc}
  """
  defmacro config_file(field, opts), do: file_attr(field, "config", opts)

  @doc """
  Declares a TLS key pair directory (`tls.crt`, `tls.key`, and `ca.crt`
  with `require_ca: true`). Extra options: `dns_names`, `key_algorithms`
  (`:rsa`, `:ecdsa`, `:ed25519`), `min_remaining` (Go duration),
  `require_ca`.

  #{@file_doc}
  """
  defmacro tls_file(field, opts), do: file_attr(field, "tls", opts)

  @doc "Declares a PEM CA bundle. Extra option: `min_certificates` (default 1).\n\n#{@file_doc}"
  defmacro ca_bundle_file(field, opts), do: file_attr(field, "caBundle", opts)

  @doc """
  Declares a keystore. Extra options: `format` (`:pkcs12` or `:jks`) and
  `password_var` (the field or env name of a declared secret variable).

  #{@file_doc}
  """
  defmacro keystore_file(field, opts), do: file_attr(field, "keystore", opts)

  @doc "Declares a text file. Extra options: `pattern` (RE2), `min_length`, `max_length`.\n\n#{@file_doc}"
  defmacro text_file(field, opts), do: file_attr(field, "text", opts)

  @doc "Declares an opaque binary file; only its size is checked.\n\n#{@file_doc}"
  defmacro binary_file(field, opts), do: file_attr(field, "binary", opts)

  defp file_attr(field, type, opts) do
    quote do
      @docuconf_files {unquote(field), unquote(type), unquote(opts)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    mod = env.module
    opts = Module.get_attribute(mod, :docuconf_opts)
    vars = mod |> Module.get_attribute(:docuconf_vars) |> Enum.reverse()
    files = mod |> Module.get_attribute(:docuconf_files) |> Enum.reverse()

    decl =
      case Declaration.build(opts, vars, files) do
        {:ok, decl} -> decl
        {:error, problems} -> raise Docuconf.DeclarationError, module: mod, problems: problems
      end

    for w <- decl.warnings, do: IO.warn("docuconf: " <> w, env)

    fields = Enum.map(decl.vars, & &1.field) ++ Enum.map(decl.files, & &1.field)

    quote do
      defstruct unquote(fields)

      @doc "The checked declaration this module was built from."
      def __docuconf__, do: unquote(Macro.escape(decl))

      @doc """
      Reads and validates the environment and file inputs. Returns
      `{:ok, %#{inspect(__MODULE__)}{}}` or `{:error, %Docuconf.ValidationError{}}`.
      See `Docuconf.load/2` for options.
      """
      def load(opts \\ []), do: Docuconf.load(__MODULE__, opts)

      @doc "Like `load/1`, but raises `Docuconf.ValidationError` listing every problem."
      def load!(opts \\ []), do: Docuconf.load!(__MODULE__, opts)

      @doc "Renders this declaration's `contract.cue`. See `Docuconf.export/2`."
      def export(opts \\ []), do: Docuconf.export(__MODULE__, opts)
    end
  end

  @doc """
  Loads `module`'s declaration from the environment.

  Options:

    * `:env` - a map to read instead of `System.get_env/0` (tests);
    * `:dotenv` - a `.env` file to read first, for development; real
      environment variables override it;
    * `:file_root` - prefixed to every absolute file path (default
      `DOCUCONF_FILE_ROOT`);
    * `:termination_log` - where to write violations, or `false` (default
      `DOCUCONF_TERMINATION_LOG`, else `/dev/termination-log` if it exists);
    * `:now` - a `DateTime` for certificate checks (tests);
    * `:warn` - `false` to silence warnings on standard error;
    * `:watcher_check` - what happens when the declaration has
      `reload: :watch` inputs and no `Docuconf.Watcher` is running for the
      module once its application has started: `:halt` (the default when
      reading the process environment) prints the problem, writes it to the
      termination log and stops the node with exit status 1; `:warn` only
      logs it; a 1-arity function receives the message; `false` (the
      default when `:env` is given) skips the check;
    * `:watcher_grace` - for a module that belongs to no application, how
      long to wait before checking, in milliseconds (default 5000).
  """
  @spec load(module(), keyword()) :: {:ok, struct()} | {:error, ValidationError.t()}
  def load(module, opts \\ []) do
    decl = module.__docuconf__()

    {result, warnings} =
      case Loader.run(decl, opts) do
        {:ok, values, warnings} ->
          Docuconf.Watcher.expect(module, decl, opts)
          {{:ok, struct!(module, values)}, warnings}

        {:error, violations, warnings} ->
          {{:error, %ValidationError{violations: violations}}, warnings}
      end

    if Keyword.get(opts, :warn, true) do
      for w <- warnings, do: IO.puts(:stderr, "docuconf: warning: " <> w)
    end

    case result do
      {:error, e} -> Loader.write_termination_log(Exception.message(e), opts)
      _ -> :ok
    end

    result
  end

  @doc "Like `load/2`, but raises `Docuconf.ValidationError`."
  @spec load!(module(), keyword()) :: struct()
  def load!(module, opts \\ []) do
    case load(module, opts) do
      {:ok, values} -> values
      {:error, e} -> raise e
    end
  end

  @doc """
  Renders `module`'s declaration as `contract.cue`. Options: `:package`
  (CUE package name) and `:app_version`.
  """
  @spec export(module(), keyword()) :: String.t()
  def export(module, opts \\ []), do: Docuconf.CUE.export(module.__docuconf__(), opts)
end
