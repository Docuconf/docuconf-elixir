defmodule Docuconf.Redacted do
  @moduledoc false
  # Inspect support for values that hold secrets: the generated config
  # struct, Docuconf.LoadedFile and contract-first values. A secret shows as
  # **redacted** (nil stays nil, so an unset secret is still visible).

  import Inspect.Algebra

  defstruct []

  defimpl Inspect do
    def inspect(_, _opts), do: "**redacted**"
  end

  @doc false
  def value(nil), do: nil
  def value(_), do: %__MODULE__{}

  @doc false
  def inspect_struct(struct, fields, secrets, opts) do
    pairs = for f <- fields, do: {f, redact(Map.get(struct, f), f in secrets)}
    name = Macro.inspect_atom(:literal, struct.__struct__)
    container_doc("#" <> name <> "<", pairs, ">", opts, &pair/2, separator: ",", break: :strict)
  end

  @doc false
  def inspect_map(map, secrets, opts) do
    pairs = map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, redact(v, k in secrets)} end)
    container_doc("%{", pairs, "}", opts, &map_pair/2, separator: ",", break: :strict)
  end

  defp redact(v, true), do: value(v)
  defp redact(v, false), do: v

  defp pair({k, v}, opts),
    do: concat([Atom.to_string(k), ": ", to_doc(v, opts)])

  defp map_pair({k, v}, opts),
    do: concat([to_doc(k, opts), " => ", to_doc(v, opts)])
end
