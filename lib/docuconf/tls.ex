defmodule Docuconf.TLS do
  @moduledoc """
  Boot-time checks for `tls` file inputs, with OTP's `:public_key`:
  the certificate and key parse and match, the certificate is valid now with
  at least `minRemaining` left, covers every name in `dnsNames`
  (`:public_key.pkix_verify_hostname/2`, wildcards included), uses an
  allowed key algorithm, and chains to `ca.crt` when `requireCA` is set
  (`:public_key.pkix_path_validation/3`).
  """

  alias Docuconf.{Duration, FileInput}

  @rsa {1, 2, 840, 113_549, 1, 1, 1}
  @ec {1, 2, 840, 10045, 2, 1}
  @ed25519 {1, 3, 101, 112}
  @ed448 {1, 3, 101, 113}

  @doc false
  # [{:ok, der} | {:error, reason}] for every CERTIFICATE block in a PEM file.
  def pem_certificates(pem) do
    try do
      :public_key.pem_decode(pem)
    rescue
      _ -> []
    end
    |> Enum.filter(&(elem(&1, 0) == :Certificate))
    |> Enum.map(fn {:Certificate, der, _} ->
      try do
        :public_key.pkix_decode_cert(der, :otp)
        {:ok, der}
      rescue
        e -> {:error, Exception.message(e)}
      catch
        _, reason -> {:error, inspect(reason)}
      end
    end)
  end

  @doc false
  def check(%FileInput{} = f, dir, report, opts) do
    crt_path = Path.join(dir, "tls.crt")
    key_path = Path.join(dir, "tls.key")
    ca_path = Path.join(dir, "ca.crt")

    crt = read(crt_path, "tls.crt", report)
    key = read(key_path, "tls.key", report)
    ca = if f.require_ca, do: read(ca_path, "ca.crt", report), else: nil

    with pem when is_binary(pem) <- crt,
         {:ok, chain} <- certs(pem, "tls.crt", report) do
      [leaf | _] = chain
      otp = :public_key.pkix_decode_cert(leaf, :otp)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      key_ok = check_key(key, otp, report)
      check_validity(f, otp, now, report)
      check_names(f, leaf, report)
      check_algorithm(f, otp, report)

      ca_ders =
        if is_binary(ca) do
          case certs(ca, "ca.crt", report) do
            {:ok, ders} ->
              check_chain(chain, ders, report)
              ders

            :error ->
              nil
          end
        end

      if is_binary(key) and key_ok do
        %Docuconf.LoadedFile{
          name: f.name,
          type: f.type,
          path: dir,
          data: %{
            certfile: crt_path,
            keyfile: key_path,
            cacertfile: if(f.require_ca, do: ca_path),
            certificate: leaf,
            chain: chain,
            cacerts: ca_ders,
            not_after: not_after(otp)
          }
        }
      end
    else
      _ -> nil
    end
  end

  defp read(path, label, report) do
    case File.read(path) do
      {:ok, bin} ->
        bin

      {:error, :enoent} ->
        report.(:file_missing, "#{label} not found in #{Path.dirname(path)}")
        nil

      {:error, reason} ->
        report.(:file_unreadable, "#{path} cannot be read (#{reason})#{Docuconf.Files.hint(reason)}")
        nil
    end
  end

  defp certs(pem, label, report) do
    case pem_certificates(pem) do
      [] ->
        report.(:certificate_invalid, "#{label} holds no PEM certificate")
        :error

      list ->
        case Enum.find_index(list, &match?({:error, _}, &1)) do
          nil ->
            {:ok, Enum.map(list, fn {:ok, der} -> der end)}

          i ->
            report.(:certificate_invalid, "#{label}: certificate #{i + 1} cannot be parsed")
            :error
        end
    end
  end

  defp decode_key(pem) do
    case :public_key.pem_decode(pem) do
      [{_, _, :not_encrypted} = entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      [{_, _, _} | _] -> {:error, "tls.key is encrypted; Kubernetes TLS secrets hold an unencrypted key"}
      [] -> {:error, "tls.key holds no PEM private key"}
    end
  rescue
    _ -> {:error, "tls.key is not a readable PEM private key"}
  end

  defp check_key(nil, _otp, _report), do: false

  defp check_key(pem, otp, report) do
    case decode_key(pem) do
      {:ok, key} ->
        if key_matches?(key, otp) do
          true
        else
          report.(:key_mismatch, "tls.key does not match the certificate in tls.crt")
          false
        end

      {:error, msg} ->
        report.(:certificate_invalid, msg)
        false
    end
  end

  # Signs a probe with the private key and verifies it with the
  # certificate's public key: works the same for RSA, ECDSA and EdDSA.
  defp key_matches?(key, otp) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, oid, params}, pub} = spki(otp)
    msg = "docuconf key match probe"

    {digest, public} =
      case oid do
        @rsa -> {:sha256, pub}
        @ec -> {:sha256, {pub, params}}
        o when o in [@ed25519, @ed448] -> {:none, {pub, {:namedCurve, o}}}
        _ -> {:sha256, pub}
      end

    sig = :public_key.sign(msg, digest, key)
    :public_key.verify(msg, digest, sig, public)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp spki(otp), do: otp |> elem(1) |> elem(7)

  defp check_validity(f, otp, now, report) do
    {from, to} = validity(otp)
    now_s = DateTime.to_unix(now)

    cond do
      now_s < DateTime.to_unix(from) ->
        report.(:certificate_invalid, "certificate is not valid until #{DateTime.to_iso8601(from)}")

      now_s > DateTime.to_unix(to) ->
        report.(:certificate_invalid, "certificate expired at #{DateTime.to_iso8601(to)}")

      f.min_remaining && (DateTime.to_unix(to) - now_s) * 1_000_000_000 < f.min_remaining ->
        left = Duration.format((DateTime.to_unix(to) - now_s) * 1_000_000_000)

        report.(
          :certificate_expiring,
          "certificate expires at #{DateTime.to_iso8601(to)} (#{left} left), less than minRemaining #{Duration.format(f.min_remaining)}"
        )

      true ->
        :ok
    end
  end

  defp not_after(otp), do: otp |> validity() |> elem(1)

  defp validity(otp) do
    {:Validity, from, to} = otp |> elem(1) |> elem(5)
    {asn1_time(from), asn1_time(to)}
  end

  defp asn1_time({:utcTime, t}) do
    <<yy::binary-size(2), rest::binary>> = to_string(t)
    y = String.to_integer(yy)
    asn1_time({:generalTime, "#{if y >= 50, do: 1900 + y, else: 2000 + y}" <> rest})
  end

  defp asn1_time({:generalTime, t}) do
    <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), h::binary-size(2), mi::binary-size(2),
      s::binary-size(2), _::binary>> = to_string(t)

    [y, mo, d, h, mi, s] = Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)
    DateTime.new!(Date.new!(y, mo, d), Time.new!(h, mi, s), "Etc/UTC")
  end

  defp check_names(%FileInput{dns_names: nil}, _leaf, _report), do: :ok

  defp check_names(%FileInput{dns_names: names}, leaf, report) do
    # The HTTPS match fun accepts a wildcard in the leftmost label only.
    match = [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]

    for name <- names, not :public_key.pkix_verify_hostname(leaf, [dns_id: String.to_charlist(name)], match) do
      report.(:certificate_name_mismatch, "certificate does not cover #{name}")
    end
  end

  @doc false
  def algorithm(otp) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, oid, _}, _} = spki(otp)

    case oid do
      @rsa -> "RSA"
      @ec -> "ECDSA"
      @ed25519 -> "Ed25519"
      other -> other |> Tuple.to_list() |> Enum.join(".")
    end
  end

  defp check_algorithm(%FileInput{key_algorithms: nil}, _otp, _report), do: :ok

  defp check_algorithm(%FileInput{key_algorithms: algs}, otp, report) do
    alg = algorithm(otp)
    unless alg in algs, do: report.(:certificate_invalid, "key algorithm #{alg} is not one of #{Enum.join(algs, ", ")}")
  end

  # tls.crt holds the leaf first, then any intermediates. The path given to
  # pkix_path_validation runs from the certificate the anchor issued down to
  # the leaf, so the intermediates are reversed, and a copy of the anchor
  # itself in tls.crt is dropped.
  defp check_chain([leaf | intermediates], ca_ders, report) do
    chains? =
      Enum.any?(ca_ders, fn anchor ->
        path = Enum.reverse(Enum.reject(intermediates, &(&1 == anchor))) ++ [leaf]

        case :public_key.pkix_path_validation(anchor, path, verify_fun: {&verify/3, nil}) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    unless chains?, do: report.(:certificate_invalid, "tls.crt does not chain to a certificate in ca.crt")
  end

  # Validity is reported on its own (certificate_invalid / _expiring), so an
  # expired certificate does not also read as a broken chain.
  defp verify(_cert, {:bad_cert, reason}, state) when reason in [:cert_expired], do: {:valid, state}
  defp verify(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}
  defp verify(_cert, {:extension, _}, state), do: {:unknown, state}
  defp verify(_cert, _event, state), do: {:valid, state}
end
