defmodule Docuconf.FilesTest do
  use ExUnit.Case, async: true

  alias Docuconf.Test.{Certs, SampleEnv}

  @routes ~s({"routes": [{"match": "/api", "upstream": "https://api.internal", "timeout": "5s"}]})
  @dns ["gateway.internal", "api.example.com"]

  setup do
    root = Path.join(System.tmp_dir!(), "docuconf-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    put(root, "/etc/gateway/routes/routes.json", @routes)
    pki = Certs.ca_and_leaf(@dns)
    Certs.write_tls_dir(p(root, "/etc/gateway/tls"), [pki.leaf], pki.leaf_key, pki.ca)
    put(root, "/etc/gateway/ca/bundle.pem", Certs.cert_pem([pki.ca]))
    put(root, "/etc/gateway/license/license.key", "ABCDE-12345-FGHIJ-67890\n")
    put(root, "/data/geoip/GeoLite2-City.mmdb", :crypto.strong_rand_bytes(64))

    env = %{
      "DATABASE_URL" => "postgres://db/gw",
      "PUBLIC_URL" => "https://gw.example.com",
      "ALLOWED_ORIGINS" => "https://a.example.com",
      "REGION" => "eu-west-1",
      "DOCUCONF_FILE_ROOT" => root
    }

    {:ok, root: root, env: env, pki: pki}
  end

  defp p(root, path), do: Path.join(root, path)

  defp put(root, path, content) do
    full = p(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp load(ctx, extra \\ %{}, opts \\ []) do
    SampleEnv.load([env: Map.merge(ctx.env, extra), termination_log: false, warn: false] ++ opts)
  end

  defp codes({:ok, _}), do: []
  defp codes({:error, e}), do: Enum.map(e.violations, &{&1.input, &1.code})

  defp tls(ctx, chain, key, ca \\ :default) do
    dir = p(ctx.root, "/etc/gateway/tls")
    File.rm_rf!(dir)
    Certs.write_tls_dir(dir, chain, key, if(ca == :default, do: ctx.pki.ca, else: ca))
  end

  test "valid files load with typed values", ctx do
    assert {:ok, env} = load(ctx)

    assert env.routes.data == %{
             routes: [%{match: "/api", upstream: "https://api.internal", timeout: "5s"}]
           }

    assert env.routes.path == p(ctx.root, "/etc/gateway/routes/routes.json")
    assert env.serving_tls.data.certfile == p(ctx.root, "/etc/gateway/tls/tls.crt")
    assert env.serving_tls.data.certificate == ctx.pki.leaf
    assert env.upstream_ca.data == [ctx.pki.ca]
    assert env.license.data == "ABCDE-12345-FGHIJ-67890\n"
    assert env.geoip.type == "binary"
    # Optional and absent.
    assert env.partner_keystore == nil
  end

  test "path_env overrides the path, and the file root still applies", ctx do
    put(
      ctx.root,
      "/elsewhere/routes.json",
      ~s({"routes": [{"match": "/x", "upstream": "http://x"}]})
    )

    assert {:ok, env} = load(ctx, %{"ROUTES_FILE" => "/elsewhere/routes.json"})
    assert env.routes.path == p(ctx.root, "/elsewhere/routes.json")
    assert [%{match: "/x"}] = env.routes.data.routes
  end

  test "missing required files", ctx do
    File.rm!(p(ctx.root, "/etc/gateway/license/license.key"))
    File.rm!(p(ctx.root, "/etc/gateway/tls/tls.key"))
    assert codes(load(ctx)) == [{"license", :file_missing}, {"serving-tls", :file_missing}]

    File.rm_rf!(p(ctx.root, "/etc/gateway/tls"))
    assert {"serving-tls", :file_missing} in codes(load(ctx))
  end

  test "malformed config and schema violations", ctx do
    put(ctx.root, "/etc/gateway/routes/routes.json", "{\"routes\": [")
    assert codes(load(ctx)) == [{"routes", :file_malformed}]

    put(
      ctx.root,
      "/etc/gateway/routes/routes.json",
      ~s({"routes": [{"match": "api", "extra": 1}]})
    )

    {:error, e} = load(ctx)
    assert [%{code: :schema_mismatch, message: msg}] = e.violations
    assert msg =~ ~s(missing required property "upstream")
    assert msg =~ ~s(unknown property "extra")
    assert msg =~ ~s(does not match pattern "^/")
  end

  test "a byte-order mark is accepted in JSON config", ctx do
    put(ctx.root, "/etc/gateway/routes/routes.json", <<0xEF, 0xBB, 0xBF>> <> @routes)
    assert {:ok, _} = load(ctx)
  end

  test "file too large", ctx do
    put(ctx.root, "/etc/gateway/routes/routes.json", String.duplicate(" ", 65_537))
    assert codes(load(ctx)) == [{"routes", :file_too_large}]
  end

  test "text pattern and CA bundle content", ctx do
    put(ctx.root, "/etc/gateway/license/license.key", "nope")
    put(ctx.root, "/etc/gateway/ca/bundle.pem", "not a pem")
    assert codes(load(ctx)) == [{"license", :pattern_mismatch}, {"upstream-ca", :file_malformed}]
  end

  test "an expiring certificate", ctx do
    leaf =
      Certs.cert(
        key: ctx.pki.leaf_key,
        dns: @dns,
        issuer: {ctx.pki.ca, ctx.pki.ca_key},
        not_after: DateTime.add(DateTime.utc_now(), 10 * 86_400)
      )

    tls(ctx, [leaf], ctx.pki.leaf_key)
    {:error, e} = load(ctx)
    assert [%{code: :certificate_expiring, message: msg}] = e.violations
    assert msg =~ "less than minRemaining 720h"
  end

  test "an expired or not-yet-valid certificate", ctx do
    now = DateTime.utc_now()

    expired =
      Certs.cert(
        key: ctx.pki.leaf_key,
        dns: @dns,
        issuer: {ctx.pki.ca, ctx.pki.ca_key},
        not_before: DateTime.add(now, -100 * 86_400),
        not_after: DateTime.add(now, -86_400)
      )

    tls(ctx, [expired], ctx.pki.leaf_key)
    assert codes(load(ctx)) == [{"serving-tls", :certificate_invalid}]

    future =
      Certs.cert(
        key: ctx.pki.leaf_key,
        dns: @dns,
        issuer: {ctx.pki.ca, ctx.pki.ca_key},
        not_before: DateTime.add(now, 86_400)
      )

    tls(ctx, [future], ctx.pki.leaf_key)
    {:error, e} = load(ctx)

    assert [%{code: :certificate_invalid, message: "certificate is not valid until " <> _}] =
             e.violations
  end

  test "a DNS name mismatch", ctx do
    leaf =
      Certs.cert(
        key: ctx.pki.leaf_key,
        dns: ["gateway.internal"],
        issuer: {ctx.pki.ca, ctx.pki.ca_key}
      )

    tls(ctx, [leaf], ctx.pki.leaf_key)
    {:error, e} = load(ctx)

    assert [
             %{
               code: :certificate_name_mismatch,
               message: "certificate does not cover api.example.com"
             }
           ] = e.violations
  end

  test "a wildcard covers one label", ctx do
    leaf =
      Certs.cert(
        key: ctx.pki.leaf_key,
        dns: ["gateway.internal", "*.example.com"],
        issuer: {ctx.pki.ca, ctx.pki.ca_key}
      )

    tls(ctx, [leaf], ctx.pki.leaf_key)
    assert {:ok, _} = load(ctx)
  end

  test "a key that does not match the certificate", ctx do
    tls(ctx, [ctx.pki.leaf], Certs.key(:ec))
    assert codes(load(ctx)) == [{"serving-tls", :key_mismatch}]
  end

  test "RSA is allowed, Ed25519 is not", ctx do
    rsa = Certs.ca_and_leaf(@dns, alg: :rsa)
    tls(ctx, [rsa.leaf], rsa.leaf_key, rsa.ca)
    assert {:ok, env} = load(ctx)

    assert Docuconf.TLS.algorithm(
             :public_key.pkix_decode_cert(env.serving_tls.data.certificate, :otp)
           ) == "RSA"

    ed = Certs.ca_and_leaf(@dns, alg: :ed25519)
    tls(ctx, [ed.leaf], ed.leaf_key, ed.ca)
    {:error, e} = load(ctx)

    assert [
             %{
               code: :certificate_invalid,
               message: "key algorithm Ed25519 is not one of ECDSA, RSA"
             }
           ] = e.violations
  end

  test "the chain must lead to ca.crt", ctx do
    other = Certs.ca_and_leaf(@dns)
    tls(ctx, [ctx.pki.leaf], ctx.pki.leaf_key, other.ca)
    {:error, e} = load(ctx)

    assert [
             %{
               code: :certificate_invalid,
               message: "tls.crt does not chain to a certificate in ca.crt"
             }
           ] = e.violations

    # leaf -> intermediate -> root, with the intermediate in tls.crt.
    root_key = Certs.key(:ec)
    root = Certs.cert(key: root_key, cn: "Root", ca: true)
    int_key = Certs.key(:ec)
    int = Certs.cert(key: int_key, cn: "Intermediate", ca: true, issuer: {root, root_key})
    leaf_key = Certs.key(:ec)
    leaf = Certs.cert(key: leaf_key, dns: @dns, issuer: {int, int_key})
    tls(ctx, [leaf, int], leaf_key, root)
    assert {:ok, env} = load(ctx)
    assert env.serving_tls.data.chain == [leaf, int]

    # Without the intermediate the chain is broken.
    tls(ctx, [leaf], leaf_key, root)
    assert codes(load(ctx)) == [{"serving-tls", :certificate_invalid}]
  end

  test "requireCA needs ca.crt", ctx do
    tls(ctx, [ctx.pki.leaf], ctx.pki.leaf_key, nil)
    assert codes(load(ctx)) == [{"serving-tls", :file_missing}]
  end

  test "certificate checks use :now", ctx do
    later = DateTime.add(DateTime.utc_now(), 80 * 86_400)
    assert codes(load(ctx, %{}, now: later)) == [{"serving-tls", :certificate_expiring}]
  end

  test "every violation, vars and files, is reported together", ctx do
    File.rm!(p(ctx.root, "/etc/gateway/license/license.key"))
    put(ctx.root, "/etc/gateway/routes/routes.json", "{}")
    tls(ctx, [ctx.pki.leaf], Certs.key(:ec))

    {:error, e} = load(ctx, %{"PORT" => "abc", "DATABASE_URL" => "", "SAMPLE_RATE" => "2"})

    assert Enum.map(e.violations, &{&1.kind, &1.input, &1.code}) == [
             {:var, "DATABASE_URL", :missing_required},
             {:var, "PORT", :invalid_type},
             {:var, "SAMPLE_RATE", :out_of_range},
             {:file, "license", :file_missing},
             {:file, "routes", :schema_mismatch},
             {:file, "serving-tls", :key_mismatch}
           ]
  end

  test "an unreadable file is file_unreadable", ctx do
    if System.cmd("id", ["-u"]) |> elem(0) |> String.trim() == "0" do
      # root reads everything; nothing to test.
      :ok
    else
      path = p(ctx.root, "/etc/gateway/license/license.key")
      File.chmod!(path, 0o000)
      {:error, e} = load(ctx)
      assert [%{code: :file_unreadable, message: msg}] = e.violations
      assert msg =~ "fsGroup"
    end
  end

  describe "keystores" do
    setup ctx do
      openssl = System.find_executable("openssl")

      if openssl == nil,
        do: {:ok, skip_ks: true},
        else: {:ok, openssl: openssl, dir: p(ctx.root, "ks-src")}
    end

    defp p12(ctx, password, extra) do
      File.mkdir_p!(ctx.dir)
      crt = Path.join(ctx.dir, "c.pem")
      key = Path.join(ctx.dir, "k.pem")
      File.write!(crt, Certs.cert_pem([ctx.pki.leaf]))
      File.write!(key, Certs.key_pem(ctx.pki.leaf_key))
      out = p(ctx.root, "/etc/gateway/partner/keystore.p12")
      File.mkdir_p!(Path.dirname(out))

      {_, 0} =
        System.cmd(
          ctx.openssl,
          [
            "pkcs12",
            "-export",
            "-in",
            crt,
            "-inkey",
            key,
            "-out",
            out,
            "-passout",
            "pass:" <> password
          ] ++ extra,
          stderr_to_stdout: true
        )

      out
    end

    test "a PKCS#12 keystore opens with its password variable", ctx do
      unless ctx[:skip_ks] do
        p12(ctx, "s3cret-pw", [])
        assert {:ok, env} = load(ctx, %{"KEYSTORE_PASSWORD" => "s3cret-pw"})
        assert env.partner_keystore.type == "keystore"

        {:error, e} = load(ctx, %{"KEYSTORE_PASSWORD" => "wrong-pw"})
        assert [%{code: :keystore_unreadable, message: msg}] = e.violations
        assert msg =~ "KEYSTORE_PASSWORD"
        refute msg =~ "wrong-pw"
      end
    end

    test "SHA-1 MACs and empty passwords", ctx do
      unless ctx[:skip_ks] do
        p12(ctx, "pw", ["-macalg", "sha1"])
        assert {:ok, _} = load(ctx, %{"KEYSTORE_PASSWORD" => "pw"})
        p12(ctx, "", [])
        assert {:ok, _} = load(ctx)
      end
    end

    test "garbage is keystore_unreadable", ctx do
      put(ctx.root, "/etc/gateway/partner/keystore.p12", "garbage")

      assert codes(load(ctx, %{"KEYSTORE_PASSWORD" => "x"})) == [
               {"partner-keystore", :keystore_unreadable}
             ]
    end

    test "JKS keystores", ctx do
      keytool = System.find_executable("keytool")

      if keytool && !ctx[:skip_ks] do
        src = p12(ctx, "changeit", [])
        jks = Path.join(ctx.dir, "ks.jks")

        {_, 0} =
          System.cmd(
            keytool,
            ~w(-importkeystore -noprompt -srckeystore #{src} -srcstoretype PKCS12 -srcstorepass changeit
                                 -destkeystore #{jks} -deststoretype JKS -deststorepass changeit),
            stderr_to_stdout: true
          )

        content = File.read!(jks)
        assert Docuconf.Keystore.verify("jks", content, "changeit") == :ok
        assert {:error, _} = Docuconf.Keystore.verify("jks", content, "nope")
      end
    end
  end
end
