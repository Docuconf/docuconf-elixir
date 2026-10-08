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

      if config_env() != :test do
        env = MyApp.Env.load!()
        config :my_app, MyApp.Repo, url: env.database_url
        config :my_app, MyAppWeb.Endpoint, http: [port: env.port]
      end

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

  Types: `:string`, `:integer` (`:pos_integer` and `:non_neg_integer` add
  `min: 1` or `min: 0`), `:float`, `:boolean`, `:duration` (Go syntax,
  `1m30s`), `:url`, `{:in, values}` (or `:enum` with `values:`; all-atom
  values load as atoms), `{:list, :string}`, `{:list, :integer}`
  (comma-separated by default) and `:json`. A duration's `default`, `min`
  and `max` may be a Go string, a string in its `encoding`, an integer in
  its `unit`, or an Elixir `Duration`.

  Options: `description` (or `doc`, at least 5 characters, required
  unless the `@doc` before the declaration gives it: see `Docuconf.Docs`),
  `details` (Markdown for generated docs, at most 4000 characters; by
  default the rest of the `@doc`), `required`, `default`, `secret`, `group`, `examples`, `deprecated`,
  `config_key`, `name`, `flag_warning`; by type, `min`/`max` (integer,
  float, duration), `min_length`/`max_length`/`pattern` (string; RE2,
  partial match; lengths in code points), `schemes` and `max_length` (url),
  `values` (enum), `min_items`/`max_items`/`separator` (list),
  `item_min`/`item_max` (integer list items), `item_min_length`/
  `item_max_length` (string list items), `schema` (json: a JSON Schema map
  or a keyword spec) and `max_length` (json: its wire string), `unit` (duration:
  `:millisecond` by default, `:second`, `:microsecond`, `:nanosecond` or
  `:duration` for an Elixir `Duration`), `encoding` (list: `:csv`, `:json`
  or `:indexed`; duration: `:go`, `:iso8601`, `:seconds` or `:timespan`).
  """
  defmacro env(field, type, opts \\ []) do
    check = ensure_used!(__CALLER__, "env")
    line = __CALLER__.line

    quote do
      unquote(check)
      doc = Docuconf.Docs.take(__MODULE__)

      @docuconf_vars {unquote(field), unquote(type), Docuconf.Docs.merge(unquote(opts), doc),
                      unquote(line)}
    end
  end

  @doc "Declares a secret environment variable: `env` with `secret: true`."
  defmacro secret(field, type, opts \\ []) do
    check = ensure_used!(__CALLER__, "secret")
    line = __CALLER__.line

    quote do
      unquote(check)
      doc = Docuconf.Docs.take(__MODULE__)

      @docuconf_vars {unquote(field), unquote(type),
                      unquote(opts) |> Keyword.put(:secret, true) |> Docuconf.Docs.merge(doc),
                      unquote(line)}
    end
  end

  # `import Docuconf` alone would make every declaration a silent no-op.
  # Attributes are set as the module body runs, so the check runs there too.
  defp ensure_used!(caller, macro) do
    if caller.module == nil do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "docuconf: #{macro} must be called inside a module that has use Docuconf"
    end

    quote do
      unless Module.has_attribute?(__MODULE__, :docuconf_opts) do
        raise CompileError,
          file: unquote(caller.file),
          line: unquote(caller.line),
          description:
            "docuconf: #{unquote(macro)} must be called inside a module that has use Docuconf, " <>
              "name: \"my-service\" (import Docuconf alone declares nothing)"
      end
    end
  end

  @file_doc """
  Common options: `description` (required, or the first paragraph of the
  `@doc` before the declaration), `details` (the rest of that `@doc`),
  `path` (absolute; required),
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
  defmacro config_file(field, opts), do: file_attr(__CALLER__, field, "config", opts)

  @doc """
  Declares a TLS key pair directory (`tls.crt`, `tls.key`, and `ca.crt`
  with `require_ca: true`). Extra options: `dns_names`, `key_algorithms`
  (`:rsa`, `:ecdsa`, `:ed25519`), `min_remaining` (Go duration),
  `require_ca`.

  #{@file_doc}
  """
  defmacro tls_file(field, opts), do: file_attr(__CALLER__, field, "tls", opts)

  @doc "Declares a PEM CA bundle. Extra option: `min_certificates` (default 1).\n\n#{@file_doc}"
  defmacro ca_bundle_file(field, opts), do: file_attr(__CALLER__, field, "caBundle", opts)

  @doc """
  Declares a keystore. Extra options: `format` (`:pkcs12` or `:jks`) and
  `password_var` (the field or env name of a declared secret variable).

  #{@file_doc}
  """
  defmacro keystore_file(field, opts), do: file_attr(__CALLER__, field, "keystore", opts)

  @doc "Declares a text file. Extra options: `pattern` (RE2), `min_length`, `max_length`.\n\n#{@file_doc}"
  defmacro text_file(field, opts), do: file_attr(__CALLER__, field, "text", opts)

  @doc "Declares an opaque binary file; only its size is checked.\n\n#{@file_doc}"
  defmacro binary_file(field, opts), do: file_attr(__CALLER__, field, "binary", opts)

  defp file_attr(caller, field, type, opts) do
    check = ensure_used!(caller, "a file declaration")
    line = caller.line

    quote do
      unquote(check)
      doc = Docuconf.Docs.take(__MODULE__)

      @docuconf_files {unquote(field), unquote(type), Docuconf.Docs.merge(unquote(opts), doc),
                       unquote(line)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    mod = env.module
    opts = Module.get_attribute(mod, :docuconf_opts)
    vars = mod |> Module.get_attribute(:docuconf_vars) |> Enum.reverse()
    files = mod |> Module.get_attribute(:docuconf_files) |> Enum.reverse()

    decl =
      case Declaration.build_located(opts, vars, files) do
        {:ok, decl} -> decl
        {:error, problems} -> declaration_error!(env, problems)
      end

    for {line, w} <- decl.warnings,
        do: IO.warn("docuconf: " <> w, %{env | line: line || env.line})

    inputs = decl.vars ++ decl.files
    fields = Enum.map(inputs, & &1.field)

    secrets =
      for(v <- decl.vars, v.secret, do: v.field) ++
        for f <- decl.files, Docuconf.FileInput.secret_data?(f), do: f.field

    types = Enum.map(inputs, &{&1.field, typespec(&1)})

    moduledoc =
      if Module.get_attribute(mod, :moduledoc) == nil do
        quote do: @moduledoc(unquote(moduledoc(decl)))
      end

    quote do
      unquote(moduledoc)

      defstruct unquote(fields)

      @typedoc "The loaded configuration: one field per declared input."
      @type t :: %__MODULE__{unquote_splicing(types)}

      unquote(inspect_impl(fields, secrets))

      @doc "The checked declaration this module was built from."
      def __docuconf__, do: unquote(Macro.escape(decl))

      @doc """
      Reads and validates the environment and file inputs. Returns
      `{:ok, %#{inspect(__MODULE__)}{}}` or `{:error, %Docuconf.ValidationError{}}`.
      See `Docuconf.load/2` for options.
      """
      @spec load(keyword()) :: {:ok, t()} | {:error, Docuconf.ValidationError.t()}
      def load(opts \\ []), do: Docuconf.load(__MODULE__, opts)

      @doc """
      Like `load/1`, but returns the struct. On invalid configuration it
      prints every problem and stops the node with exit status 1 (when
      reading the process environment), or raises `Docuconf.ValidationError`
      (when given `env:`). See `Docuconf.load!/2`.
      """
      @spec load!(keyword()) :: t()
      def load!(opts \\ []), do: Docuconf.load!(__MODULE__, opts)

      @doc "Renders this declaration's `contract.cue`. See `Docuconf.export/2`."
      def export(opts \\ []), do: Docuconf.export(__MODULE__, opts)
    end
  end

  # Secrets are redacted wherever the struct is inspected: IEx, Logger,
  # crash reports, :observer. A module compiled after protocols were
  # consolidated (one defined in a test file) cannot add an implementation,
  # so none is emitted there rather than one that would only warn.
  defp inspect_impl(fields, secrets) do
    unless Protocol.consolidated?(Inspect) do
      quote do
        defimpl Inspect do
          def inspect(struct, opts),
            do: Docuconf.Redacted.inspect_struct(struct, unquote(fields), unquote(secrets), opts)
        end
      end
    end
  end

  # Raises the declaration problems with each one's file:line, and with a
  # stacktrace that points editors and the compiler at the first of them
  # rather than at `defmodule`.
  defp declaration_error!(env, problems) do
    file = Path.relative_to_cwd(env.file)

    messages =
      Enum.map(problems, fn
        {nil, msg} -> msg
        {line, msg} -> "#{file}:#{line}: #{msg}"
      end)

    line = Enum.find_value(problems, env.line, fn {l, _} -> l end)
    stack = [{env.module, :__MODULE__, 0, [file: String.to_charlist(env.file), line: line]}]
    reraise Docuconf.DeclarationError, [module: env.module, problems: messages], stack
  end

  defp typespec(%Docuconf.FileInput{required: required}) do
    nilable(quote(do: Docuconf.LoadedFile.t()), required)
  end

  defp typespec(%Docuconf.Var{} = v) do
    base =
      case v.type do
        "string" -> quote(do: String.t())
        "url" -> quote(do: String.t())
        "int" when is_integer(v.min) and v.min >= 1 -> quote(do: pos_integer())
        "int" when is_integer(v.min) and v.min >= 0 -> quote(do: non_neg_integer())
        "int" -> quote(do: integer())
        "float" -> quote(do: float())
        "bool" -> quote(do: boolean())
        "duration" when v.unit == :duration -> quote(do: Duration.t())
        "duration" -> quote(do: integer())
        "enum" when v.atom_values -> v.values |> Enum.map(&String.to_atom/1) |> union()
        "enum" -> quote(do: String.t())
        "list" when v.items == "int" -> quote(do: [integer()])
        "list" -> quote(do: [String.t()])
        "json" -> quote(do: term())
      end

    nilable(base, v.required or v.has_default)
  end

  defp nilable(ast, true), do: ast
  defp nilable(ast, false), do: {:|, [], [ast, nil]}

  defp union([a]), do: a
  defp union([a | rest]), do: {:|, [], [a, union(rest)]}

  defp moduledoc(decl) do
    cell = fn s -> s |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ") end

    vars =
      for v <- decl.vars do
        default =
          cond do
            v.secret -> "secret"
            v.required -> "required"
            v.has_default -> "`#{cell.(Docuconf.CUE.default_text(v))}`"
            true -> ""
          end

        "| `#{v.name}` | #{v.type} | #{default} | #{cell.(v.description)} |"
      end

    files =
      for f <- decl.files do
        "| `#{f.name}` | #{f.type} | `#{f.path}`#{if f.required, do: " (required)", else: ""} | #{cell.(f.description)} |"
      end

    """
    The configuration of #{decl.name}, declared with `use Docuconf`.

    | Variable | Type | Default | Description |
    |---|---|---|---|
    #{Enum.join(vars, "\n")}
    """ <>
      if files == [],
        do: "",
        else: """

        | File input | Type | Path | Description |
        |---|---|---|---|
        #{Enum.join(files, "\n")}
        """
  end

  @doc """
  Loads `module`'s declaration from the environment.

  Options:

    * `:env` - a map to read instead of `System.get_env/0` (tests);
    * `:dotenv` - a `.env` file to read first, for development; real
      environment variables override it. `nil` or `false` reads none, so
      `dotenv: config_env() == :dev && ".env"` works. A named file that does
      not exist gives a warning;
    * `:fallback_env` - a map of variable name to value used only for
      variables that neither the environment nor the `.env` file sets, for
      development values that do not belong in the contract (a dev
      `SECRET_KEY_BASE`). `nil` or `false` uses none;
    * `:file_root` - prefixed to every absolute file path (default
      `DOCUCONF_FILE_ROOT`);
    * `:termination_log` - where to write violations, or `false` (default
      `DOCUCONF_TERMINATION_LOG`, else `/dev/termination-log` if it exists;
      `false` when `:env` is given, so tests never write it);
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
      long to wait before checking, in milliseconds (default 5000);
    * `:on_error` - for `load!/2` only, see there.

  Warnings go to standard error: a deprecated variable that is set, a secret
  ending in a newline, a missing `.env` file, and a set variable whose name
  is one or two edits from a declared one (`DATABSE_URL is set but not
  declared; did you mean DATABASE_URL?`).
  """
  @spec load(module(), keyword()) :: {:ok, struct()} | {:error, ValidationError.t()}
  def load(module, opts \\ []) do
    decl = module.__docuconf__()

    {result, warnings} =
      case Loader.run(decl, opts) do
        {:ok, values, warnings} ->
          Docuconf.Watcher.remember(module, opts)
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

  @doc """
  Like `load/2`, but returns the struct, and on invalid configuration
  either stops the node or raises, by `:on_error`:

    * `:halt` (the default when reading the process environment, that is
      at boot): prints `docuconf: N configuration problems:` and one line
      per problem to standard error, with no stack trace, and stops the
      node with exit status 1. The termination log is written as by
      `load/2`. In `config/runtime.exs` this is a clean boot failure in
      `mix run`, `mix phx.server` and in a release, with no crash dump;
    * `:raise` (the default when `:env` is given, as in tests): raises
      `Docuconf.ValidationError` listing every problem.
  """
  @spec load!(module(), keyword()) :: struct()
  def load!(module, opts \\ []) do
    on_error!(opts)

    case load(module, opts) do
      {:ok, values} -> values
      {:error, e} -> fail!(e, opts)
    end
  end

  defp on_error!(opts) do
    default = if Keyword.has_key?(opts, :env), do: :raise, else: :halt

    case Keyword.get(opts, :on_error, default) do
      mode when mode in [:halt, :raise] ->
        mode

      other ->
        raise ArgumentError, "docuconf: :on_error must be :halt or :raise, got: #{inspect(other)}"
    end
  end

  @doc false
  def fail!(%ValidationError{} = e, opts) do
    case on_error!(opts) do
      :raise ->
        raise e

      :halt ->
        IO.puts(:stderr, Exception.message(e))
        System.halt(1)
    end
  end

  @doc """
  Renders `module`'s declaration as `contract.cue`. Options: `:package`
  (CUE package name) and `:app_version`.
  """
  @spec export(module(), keyword()) :: String.t()
  def export(module, opts \\ []), do: Docuconf.CUE.export(module.__docuconf__(), opts)
end
