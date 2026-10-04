defmodule Docuconf.Violation do
  @moduledoc """
  One problem found while validating the environment or a file input at
  boot. `message` never contains a secret value.
  """

  @codes ~w(missing_required invalid_type out_of_range pattern_mismatch not_in_enum
            invalid_scheme too_few_items too_many_items file_missing file_unreadable
            file_too_large file_malformed schema_mismatch certificate_invalid
            certificate_expiring certificate_name_mismatch key_mismatch keystore_unreadable)a

  @typedoc "The stable error codes of SPEC §11.2 item 5."
  @type code ::
          :missing_required
          | :invalid_type
          | :out_of_range
          | :pattern_mismatch
          | :not_in_enum
          | :invalid_scheme
          | :too_few_items
          | :too_many_items
          | :file_missing
          | :file_unreadable
          | :file_too_large
          | :file_malformed
          | :schema_mismatch
          | :certificate_invalid
          | :certificate_expiring
          | :certificate_name_mismatch
          | :key_mismatch
          | :keystore_unreadable

  @type t :: %__MODULE__{input: String.t(), kind: :var | :file, code: code(), message: String.t()}
  @enforce_keys [:input, :kind, :code, :message]
  defstruct [:input, :kind, :code, :message]

  @doc "Every stable error code."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc false
  def new(input, kind, code, message) when code in @codes,
    do: %__MODULE__{input: input, kind: kind, code: code, message: message}

  @doc "Formats one violation as `INPUT [code]: message`."
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = v), do: "#{v.input} [#{v.code}]: #{v.message}"
end

defmodule Docuconf.ValidationError do
  @moduledoc """
  Raised by `load!/1` when the environment or a file input is invalid.
  `violations` holds every problem found, not just the first.
  """
  defexception [:violations]

  @type t :: %__MODULE__{violations: [Docuconf.Violation.t()]}

  @impl true
  def message(%{violations: vs}) do
    n = length(vs)
    lines = Enum.map_join(vs, "\n", &("  - " <> Docuconf.Violation.format(&1)))
    "docuconf: #{n} configuration problem#{if n == 1, do: "", else: "s"}:\n#{lines}"
  end
end

defmodule Docuconf.DeclarationError do
  @moduledoc "Raised at compile time when a declaration is itself invalid (SPEC §11.2 item 2)."
  defexception [:module, :problems]

  @impl true
  def message(%{module: mod, problems: ps}) do
    where = if mod, do: " in #{inspect(mod)}", else: ""
    "docuconf: invalid declaration#{where}:\n" <> Enum.map_join(ps, "\n", &("  - " <> &1))
  end
end
