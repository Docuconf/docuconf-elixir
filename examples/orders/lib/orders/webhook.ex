defmodule Orders.Webhook do
  @moduledoc """
  Checks the signature on incoming payment webhooks against the key set in
  `WEBHOOK_KEYS`.
  """

  @doc """
  Whether `signature`, the hex HMAC-SHA256 of `body`, was made with any of
  `keys`. Accepting every key in the set is what lets a key be rotated:
  during the overlap the old and the new key both work.
  """
  @spec verify([String.t()] | nil, iodata(), String.t() | nil) :: boolean()
  def verify(keys, body, signature) do
    signature = String.downcase(signature || "")

    Enum.reduce(keys || [], false, fn key, ok ->
      want = :crypto.mac(:hmac, :sha256, key, body) |> Base.encode16(case: :lower)
      # Check every key, so the time taken does not say which one matched.
      equal?(want, signature) or ok
    end)
  end

  defp equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp equal?(_, _), do: false
end
