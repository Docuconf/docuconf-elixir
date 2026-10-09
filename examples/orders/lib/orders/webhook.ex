defmodule Orders.Webhook do
  @moduledoc """
  Checks the signature on incoming payment webhooks against the key set in
  `WEBHOOK_KEYS`.
  """

  @doc """
  Whether `signature`, the hex HMAC-SHA256 of `body`, was made with any key
  in `keys`. Accepting every key in the set is what lets a key be rotated:
  during the overlap the old and the new key both work.
  `Docuconf.KeySet.verify?/2` tries every key, without stopping at the
  first match, so the time taken does not say which one matched. No keys
  (`WEBHOOK_KEYS` unset) accepts nothing.
  """
  @spec verify(Docuconf.KeySet.t() | nil, iodata(), String.t() | nil) :: boolean()
  def verify(keys, body, signature) do
    signature = String.downcase(signature || "")

    Docuconf.KeySet.verify?(keys, fn key ->
      want = :crypto.mac(:hmac, :sha256, key, body) |> Base.encode16(case: :lower)
      byte_size(want) == byte_size(signature) and :crypto.hash_equals(want, signature)
    end)
  end
end
