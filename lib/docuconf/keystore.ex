defmodule Docuconf.Keystore do
  @moduledoc """
  Opens keystores with their password, to check at boot that a `keystore`
  input is readable with the password from its `password_var`.

  OTP has no PKCS#12 reader, so docuconf parses the PFX structure (DER) and
  verifies its integrity MAC (RFC 7292: PKCS#12 key derivation and HMAC with
  SHA-1 or SHA-2). A correct MAC proves the password is right and the file
  is intact; the encrypted contents are not decrypted. JKS and JCEKS stores
  are checked the same way with their SHA-1 integrity digest.

  Not supported: PKCS#12 files with no MAC (rare, password cannot be
  checked), PBMAC1 MACs (OpenSSL 3.4+ `-pbmac1_pbkdf2`) and BER
  indefinite-length encodings. These report `keystore_unreadable` with the
  reason.
  """

  import Bitwise

  @hashes %{
    {1, 3, 14, 3, 2, 26} => {:sha, 64},
    {2, 16, 840, 1, 101, 3, 4, 2, 4} => {:sha224, 64},
    {2, 16, 840, 1, 101, 3, 4, 2, 1} => {:sha256, 64},
    {2, 16, 840, 1, 101, 3, 4, 2, 2} => {:sha384, 128},
    {2, 16, 840, 1, 101, 3, 4, 2, 3} => {:sha512, 128}
  }
  @pbmac1 {1, 2, 840, 113_549, 1, 5, 14}

  @doc "Verifies `content` opens with `password`. `format` is \"pkcs12\" or \"jks\"."
  @spec verify(String.t(), binary(), String.t()) :: :ok | {:error, String.t()}
  def verify("pkcs12", content, password), do: pkcs12(content, password)
  def verify("jks", content, password), do: jks(content, password)

  # ---- PKCS#12 -------------------------------------------------------------

  defp pkcs12(der, password) do
    with {:ok, {0x30, pfx}, ""} <- tlv(der),
         {:ok, [{0x02, _version}, {0x30, auth_safe} | mac]} <- seq(pfx),
         {:ok, data} <- auth_safe_data(auth_safe),
         {:ok, mac_data} <- mac_data(mac),
         {:ok, {hash, block, digest, salt, iterations}} <- mac_params(mac_data) do
      size = byte_size(digest)

      # An empty password is encoded as the two-byte BMP terminator by
      # OpenSSL, and as nothing at all by some other tools; try both.
      candidates = if password == "", do: [bmp(""), ""], else: [bmp(password)]

      ok? =
        Enum.any?(candidates, fn pw ->
          key = kdf(hash, block, pw, salt, 3, iterations, size)
          :crypto.mac(:hmac, hash, key, data) == digest
        end)

      if ok?,
        do: :ok,
        else: {:error, "wrong password or corrupted file: the integrity MAC does not match"}
    else
      {:error, _} = e -> e
      _ -> {:error, "not a DER-encoded PKCS#12 (PFX) file"}
    end
  end

  defp auth_safe_data(auth_safe) do
    with {:ok, [{0x06, _oid}, {0xA0, explicit}]} <- seq(auth_safe),
         {:ok, {0x04, data}, ""} <- tlv(explicit) do
      {:ok, data}
    else
      _ ->
        {:error,
         "PKCS#12 authSafe is not plain data (public-key integrity mode is not supported)"}
    end
  end

  defp mac_data([{0x30, mac_data}]), do: {:ok, mac_data}

  defp mac_data([]),
    do: {:error, "the PKCS#12 file has no integrity MAC, so its password cannot be checked"}

  defp mac_data(_), do: {:error, "malformed PKCS#12 MacData"}

  defp mac_params(mac_data) do
    with {:ok, [{0x30, digest_info}, {0x04, salt} | rest]} <- seq(mac_data),
         {:ok, [{0x30, alg}, {0x04, digest}]} <- seq(digest_info),
         {:ok, [{0x06, oid_der} | _]} <- seq(alg) do
      oid = decode_oid(oid_der)

      iterations =
        case rest do
          [{0x02, i}] -> :binary.decode_unsigned(i)
          [] -> 1
        end

      case @hashes[oid] do
        {hash, block} -> {:ok, {hash, block, digest, salt, iterations}}
        nil when oid == @pbmac1 -> {:error, "PBMAC1 integrity MACs are not supported yet"}
        nil -> {:error, "unsupported MAC digest #{Enum.join(Tuple.to_list(oid), ".")}"}
      end
    else
      _ -> {:error, "malformed PKCS#12 MacData"}
    end
  end

  defp bmp(password) do
    (password |> :unicode.characters_to_binary(:utf8, {:utf16, :big})) <> <<0, 0>>
  end

  # RFC 7292 appendix B.2.
  defp kdf(hash, v, password, salt, id, iterations, n) do
    d = :binary.copy(<<id>>, v)
    s = stretch(salt, v)
    p = stretch(password, v)
    i = s <> p
    c = div(n + hash_len(hash) - 1, hash_len(hash))

    {out, _} =
      Enum.reduce(1..c, {"", i}, fn _, {acc, i} ->
        a = Enum.reduce(1..iterations, d <> i, fn _, x -> :crypto.hash(hash, x) end)
        b = stretch(a, v) |> binary_part(0, v) |> :binary.decode_unsigned()

        i =
          for <<block::binary-size(v) <- i>>, into: "" do
            sum = :binary.decode_unsigned(block) + b + 1
            <<sum &&& (1 <<< (v * 8)) - 1::size(v * 8)>>
          end

        {acc <> a, i}
      end)

    binary_part(out, 0, n)
  end

  defp hash_len(hash), do: byte_size(:crypto.hash(hash, ""))

  # Repeats `bin` to fill v * ceil(len/v) bytes (empty stays empty).
  defp stretch("", _v), do: ""

  defp stretch(bin, v) do
    len = v * div(byte_size(bin) + v - 1, v)
    reps = div(len, byte_size(bin)) + 1
    binary_part(:binary.copy(bin, reps), 0, len)
  end

  # ---- DER -----------------------------------------------------------------

  defp tlv(<<tag, 0x80, _::binary>>) when tag in [0x30, 0x24, 0xA0],
    do: {:error, "BER indefinite-length encoding is not supported; convert with openssl pkcs12"}

  defp tlv(<<tag, len, rest::binary>>) when len < 0x80 and byte_size(rest) >= len do
    <<value::binary-size(len), rest::binary>> = rest
    {:ok, {tag, value}, rest}
  end

  defp tlv(<<tag, 1::1, n::7, rest::binary>>) when n in 1..4 and byte_size(rest) >= n do
    <<len::size(n * 8), rest::binary>> = rest

    if byte_size(rest) >= len do
      <<value::binary-size(len), rest::binary>> = rest
      {:ok, {tag, value}, rest}
    else
      :error
    end
  end

  defp tlv(_), do: :error

  defp seq(bin, acc \\ [])
  defp seq("", acc), do: {:ok, Enum.reverse(acc)}

  defp seq(bin, acc) do
    case tlv(bin) do
      {:ok, item, rest} -> seq(rest, [item | acc])
      other -> other
    end
  end

  defp decode_oid(<<first, rest::binary>>) do
    {arcs, _} =
      for <<more::1, bits::7 <- rest>>, reduce: {[], 0} do
        {arcs, acc} ->
          acc = acc <<< 7 ||| bits
          if more == 1, do: {arcs, acc}, else: {[acc | arcs], 0}
      end

    List.to_tuple([div(first, 40), rem(first, 40) | Enum.reverse(arcs)])
  end

  # ---- JKS / JCEKS ---------------------------------------------------------

  defp jks(<<magic::32, _::binary>> = content, password)
       when magic in [0xFEEDFEED, 0xCECECECE] and byte_size(content) > 20 do
    body = binary_part(content, 0, byte_size(content) - 20)
    digest = binary_part(content, byte_size(content) - 20, 20)
    pw = :unicode.characters_to_binary(password, :utf8, {:utf16, :big})

    if :crypto.hash(:sha, [pw, "Mighty Aphrodite", body]) == digest,
      do: :ok,
      else: {:error, "wrong password or corrupted file: the integrity digest does not match"}
  end

  defp jks(_content, _password), do: {:error, "not a JKS or JCEKS keystore"}
end
