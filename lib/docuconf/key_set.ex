defmodule Docuconf.KeySet do
  @moduledoc """
  The value of a `:key_set` variable (SPEC §4.3): a set of secret keys that
  are all valid at once, so one can be rotated without an outage. It is for
  the side that verifies: webhook signatures, inbound API keys, JWT HMAC
  verification, cookie-signing fallbacks.

      secret :webhook_keys, :key_set,
        description: "Keys that verify webhook signatures",
        key_min_length: 32

      # in the webhook handler
      Docuconf.KeySet.verify?(env.webhook_keys, fn key ->
        expected = :crypto.mac(:hmac, :sha256, key, body)
        byte_size(expected) == byte_size(signature) and :crypto.hash_equals(expected, signature)
      end)

  The keys are always secret. `inspect/2` (and so IEx, Logger and crash
  reports) and `to_string/1` show `#Docuconf.KeySet<2 keys, redacted>` and
  `**redacted**`, and the keys are held behind a function, so even a raw
  Erlang term dump (`:io.format("~p")`) does not print them. Read them with
  `keys/1`.
  """

  @enforce_keys [:keys]
  defstruct [:keys]

  @opaque t :: %__MODULE__{keys: (-> [String.t()])}

  @doc false
  @spec new([String.t()]) :: t()
  def new(keys) when is_list(keys) do
    %__MODULE__{keys: fn -> keys end}
  end

  @doc "The keys, in the order the platform gave them (during a rotation: old, then new)."
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{keys: f}), do: f.()

  @doc "The number of keys."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = ks), do: length(keys(ks))

  @doc """
  Whether `candidate` is one of the keys, as for an inbound API key. Every
  key is compared, each in constant time (`:crypto.hash_equals/2` on
  SHA-256 digests, so keys of different lengths take the same time), so the
  time taken says neither which key matched nor how much of one did.
  """
  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{} = ks, candidate) when is_binary(candidate) do
    digest = :crypto.hash(:sha256, candidate)

    Enum.reduce(keys(ks), false, fn key, found ->
      :crypto.hash_equals(:crypto.hash(:sha256, key), digest) or found
    end)
  end

  def contains?(%__MODULE__{}, _candidate), do: false

  @doc """
  Runs `check` against every key and returns whether any accepted it. It
  never stops at the first match, so the time taken does not say which key
  matched. `check` gets one key and returns a boolean; it should itself
  compare in constant time (`:crypto.hash_equals/2`), as for an HMAC:

      Docuconf.KeySet.verify?(keys, fn key ->
        expected = :crypto.mac(:hmac, :sha256, key, body) |> Base.encode16(case: :lower)
        byte_size(expected) == byte_size(signature) and :crypto.hash_equals(expected, signature)
      end)

  A `nil` key set (an optional variable that is unset) accepts nothing.
  """
  @spec verify?(t() | nil, (String.t() -> boolean())) :: boolean()
  def verify?(nil, check) when is_function(check, 1), do: false

  def verify?(%__MODULE__{} = ks, check) when is_function(check, 1) do
    Enum.reduce(keys(ks), false, fn key, ok -> check.(key) == true or ok end)
  end

  defimpl Inspect do
    def inspect(ks, _opts) do
      n = Docuconf.KeySet.size(ks)
      "#Docuconf.KeySet<#{n} key#{if n == 1, do: "", else: "s"}, redacted>"
    end
  end

  defimpl String.Chars do
    def to_string(_ks), do: "**redacted**"
  end
end
