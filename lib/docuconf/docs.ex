defmodule Docuconf.Docs do
  @moduledoc """
  Where an input's `description` and `details` come from (SPEC §4.2, §14.7).

  The `@doc` written directly before `env`, `secret` or a file declaration
  documents that input: its first paragraph is the description (on one line,
  without a final period) and the rest is the details, in Markdown:

      @doc \"\"\"
      HTTP listen port.

      Behind the mesh, keep the default.
      \"\"\"
      env :port, :integer, default: 8080

  The `description:` and `details:` options set either one explicitly and win
  over the `@doc`. ExDoc-specific syntax becomes CommonMark: auto-link
  prefixes (`` `m:Mod` ``, `` `t:Mod.t/0` ``, `` `c:Mod.cb/1` ``) are dropped,
  `[text](`Mod.fun/1`)` links become code spans, and IAL attributes such as
  `{: .info}` are removed.
  """

  @max_details 4000

  @doc false
  # Called in the module body by the declaration macros: the pending @doc,
  # which it consumes so it does not attach to the next function.
  def take(module) do
    doc = Module.get_attribute(module, :doc)
    Module.delete_attribute(module, :doc)

    case doc do
      {_line, text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  @doc false
  # The declaration's options with `description` and `details` filled from
  # `doc`, where they are not given.
  def merge(opts, nil), do: opts

  def merge(opts, doc) when is_list(opts) and is_binary(doc) do
    {first, rest} = split(doc)

    opts =
      if Keyword.has_key?(opts, :description) or Keyword.has_key?(opts, :doc) or first == "",
        do: opts,
        else: Keyword.put(opts, :description, first)

    details = to_markdown(rest)

    if Keyword.has_key?(opts, :details) or details == "",
      do: opts,
      else: Keyword.put(opts, :details, details)
  end

  def merge(opts, _doc), do: opts

  @doc """
  Splits a doc into its first paragraph, on one line without a final
  period, and the rest.
  """
  @spec split(String.t()) :: {String.t(), String.t()}
  def split(doc) do
    case doc |> String.trim() |> String.split(~r/\n[ \t]*\n/, parts: 2) do
      [""] ->
        {"", ""}

      [first | rest] ->
        first = first |> String.split() |> Enum.join(" ")

        first =
          if String.ends_with?(first, ".") and not String.ends_with?(first, ".."),
            do: String.slice(first, 0..-2//1),
            else: first

        {first, rest |> Enum.join() |> String.trim("\n") |> String.trim_trailing()}
    end
  end

  @doc "Converts ExDoc Markdown to CommonMark."
  @spec to_markdown(String.t()) :: String.t()
  def to_markdown(text) do
    {lines, _} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(false, fn line, fenced ->
        cond do
          String.starts_with?(String.trim_leading(line), ["```", "~~~"]) -> {line, not fenced}
          fenced -> {line, fenced}
          true -> {inline(line), fenced}
        end
      end)

    lines
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp inline(line) do
    line = Regex.replace(~r/\s*\{:\s*[^}]*\}\s*$/, line, "")
    line = Regex.replace(~r/\[`([^`]+)`\]\(`[^`)]+`\)/, line, "`\\1`")
    line = Regex.replace(~r/\[([^\]`]+)\]\(`[^`)]+`\)/, line, "`\\1`")
    Regex.replace(~r/`(?:[mtce]|h|task):([^`]+)`/, line, "`\\1`")
  end

  @doc false
  # Problems with details: blank, or longer than 4000 code points.
  def problems(nil), do: []

  def problems(details) when is_binary(details) do
    n = details |> String.codepoints() |> length()

    cond do
      String.trim(details) == "" -> ["details must not be blank"]
      n > @max_details -> ["details are #{n} characters; at most #{@max_details} are allowed"]
      true -> []
    end
  end

  def problems(other), do: ["details must be a string, got #{inspect(other)}"]
end
