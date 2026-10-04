defmodule Docuconf.Test.Certs do
  @moduledoc false
  # Generates keys and X.509 certificates for tests with :public_key alone.

  @ec_curve {1, 2, 840, 10045, 3, 1, 7}

  def key(:ec), do: :public_key.generate_key({:namedCurve, @ec_curve})
  def key(:rsa), do: :public_key.generate_key({:rsa, 2048, 65537})
  def key(:ed25519), do: :public_key.generate_key({:namedCurve, :ed25519})

  @doc """
  Issues a certificate. Options: `:key` (subject key), `:cn`, `:dns` (SANs),
  `:not_before`, `:not_after` (DateTime), `:ca` (bool), `:issuer`
  ({cert_der, issuer_key}; self-signed when absent), `:serial`.
  """
  def cert(opts) do
    key = Keyword.fetch!(opts, :key)
    now = DateTime.utc_now()
    not_before = Keyword.get(opts, :not_before, DateTime.add(now, -3600))
    not_after = Keyword.get(opts, :not_after, DateTime.add(now, 90 * 86_400))
    subject = name(Keyword.get(opts, :cn, "test"))

    {issuer_name, signing_key} =
      case opts[:issuer] do
        nil ->
          {subject, key}

        {issuer_der, issuer_key} ->
          otp = :public_key.pkix_decode_cert(issuer_der, :otp)
          {otp |> elem(1) |> elem(6), issuer_key}
      end

    exts =
      Enum.reject(
        [
          opts[:dns] &&
            {:Extension, {2, 5, 29, 17}, false,
             Enum.map(opts[:dns], &{:dNSName, String.to_charlist(&1)})},
          opts[:ca] &&
            {:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, :asn1_NOVALUE}},
          opts[:ca] && {:Extension, {2, 5, 29, 15}, true, [:keyCertSign, :cRLSign]}
        ],
        &(&1 in [nil, false])
      )

    tbs =
      {:OTPTBSCertificate, :v3, Keyword.get(opts, :serial, :rand.uniform(1_000_000_000)),
       sig_alg(signing_key), issuer_name, {:Validity, time(not_before), time(not_after)}, subject,
       spki(key), :asn1_NOVALUE, :asn1_NOVALUE, if(exts == [], do: :asn1_NOVALUE, else: exts)}

    :public_key.pkix_sign(tbs, signing_key)
  end

  defp name(cn), do: {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}}]]}

  defp time(dt) do
    {:generalTime, dt |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}
  end

  defp sig_alg({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _}),
    do: {:SignatureAlgorithm, {1, 2, 840, 113_549, 1, 1, 11}, :NULL}

  defp sig_alg({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _, _}),
    do: {:SignatureAlgorithm, {1, 3, 101, 112}, :asn1_NOVALUE}

  defp sig_alg({:ECPrivateKey, _, _, _, _, _}),
    do: {:SignatureAlgorithm, {1, 2, 840, 10045, 4, 3, 2}, :asn1_NOVALUE}

  defp spki({:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _}),
    do:
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 113_549, 1, 1, 1}, :NULL},
       {:RSAPublicKey, n, e}}

  defp spki({:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, pub, _}),
    do:
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 3, 101, 112}, :asn1_NOVALUE},
       {:ECPoint, pub}}

  defp spki({:ECPrivateKey, _, _, curve, pub, _}),
    do:
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1}, curve},
       {:ECPoint, pub}}

  def cert_pem(ders),
    do: :public_key.pem_encode(Enum.map(List.wrap(ders), &{:Certificate, &1, :not_encrypted}))

  def key_pem({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = k),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, k)])

  def key_pem(k), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, k)])

  @doc "Writes a kubernetes.io/tls directory: tls.crt (chain), tls.key and optionally ca.crt."
  def write_tls_dir(dir, chain, key, ca \\ nil) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "tls.crt"), cert_pem(chain))
    File.write!(Path.join(dir, "tls.key"), key_pem(key))
    if ca, do: File.write!(Path.join(dir, "ca.crt"), cert_pem(ca))
    dir
  end

  @doc "A CA, and a leaf it issued for `dns`."
  def ca_and_leaf(dns, opts \\ []) do
    ca_key = key(:ec)
    ca = cert(key: ca_key, cn: "Test CA", ca: true)
    leaf_key = key(Keyword.get(opts, :alg, :ec))
    leaf = cert(Keyword.merge([key: leaf_key, cn: hd(dns), dns: dns, issuer: {ca, ca_key}], opts))
    %{ca: ca, ca_key: ca_key, leaf: leaf, leaf_key: leaf_key}
  end
end
