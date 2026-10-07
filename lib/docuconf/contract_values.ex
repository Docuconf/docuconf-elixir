defmodule Docuconf.Contract.Values do
  @moduledoc """
  The values loaded in contract-first mode, keyed by variable name
  (`"PORT"`) and file input name (`"serving-tls"`).

  Read them with `Access` (`values["PORT"]`, `get_in/2`) or `fetch/2`, or
  get a plain map with `to_map/1`. `inspect/2` (and so IEx, Logger and crash
  reports) shows secret values as `**redacted**`; a plain map from
  `to_map/1` does not.
  """

  @behaviour Access

  @type t :: %__MODULE__{values: %{String.t() => term()}, secrets: [String.t()]}
  defstruct values: %{}, secrets: []

  @doc "The values as a plain map. Secrets are not redacted."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{values: v}), do: v

  @impl Access
  def fetch(%__MODULE__{values: v}, key), do: Map.fetch(v, key)

  @impl Access
  def get_and_update(%__MODULE__{values: v} = s, key, fun) do
    {got, v} = Map.get_and_update(v, key, fun)
    {got, %{s | values: v}}
  end

  @impl Access
  def pop(%__MODULE__{values: v} = s, key) do
    {got, v} = Map.pop(v, key)
    {got, %{s | values: v}}
  end

  defimpl Inspect do
    def inspect(%{values: v, secrets: secrets}, opts) do
      Inspect.Algebra.concat([
        "#Docuconf.Contract.Values<",
        Docuconf.Redacted.inspect_map(v, secrets, opts),
        ">"
      ])
    end
  end
end
