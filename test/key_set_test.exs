defmodule Docuconf.KeySetTest do
  # The keySet type (SPEC §4.3): declaration, parsing, errors, export, and
  # the verifier helpers.
  use ExUnit.Case, async: true

  alias Docuconf.{DeclarationError, KeySet, ValidationError}

  @old "old-webhook-key-0123456789abcdef0123"
  @new "new-webhook-key-0123456789abcdef0123"

  defmodule Env do
    use Docuconf, name: "key-sets"

    @doc "Keys that verify webhook signatures"
    secret :webhook_keys, :key_set, key_min_length: 32, key_max_length: 256

    @doc "API keys callers present, as a JSON array"
    env :api_keys, :key_set, encoding: :json, max_keys: 3

    @doc "Cookie-signing keys, one variable each"
    secret :signing_keys, :key_set, encoding: :indexed
  end

  defp load(env), do: Env.load(env: env, warn: false)

  defp codes({:error, %ValidationError{violations: vs}}),
    do: Enum.map(vs, &{&1.input, &1.code})

  test "keys come back in order, in every encoding" do
    {:ok, env} =
      load(%{
        "WEBHOOK_KEYS" => "#{@old},#{@new}",
        "API_KEYS" => ~s(["key-one","key,two"]),
        "SIGNING_KEYS__0" => "cookie-old",
        "SIGNING_KEYS__1" => "cookie-new"
      })

    assert KeySet.keys(env.webhook_keys) == [@old, @new]
    assert KeySet.keys(env.api_keys) == ["key-one", "key,two"]
    assert KeySet.keys(env.signing_keys) == ["cookie-old", "cookie-new"]
    assert KeySet.size(env.webhook_keys) == 2
  end

  test "an unset key set is nil, and an empty value is unset" do
    assert {:ok, %{webhook_keys: nil, api_keys: nil}} = load(%{"WEBHOOK_KEYS" => ""})
  end

  test "keys are never trimmed" do
    padded = " #{String.slice(@old, 0, 33)} "
    {:ok, env} = load(%{"WEBHOOK_KEYS" => padded})
    assert KeySet.keys(env.webhook_keys) == [padded]
  end

  test "too few, too many, empty and out-of-range keys, never printing a key" do
    for {env, want} <- [
          {%{"WEBHOOK_KEYS" => "#{@old},"}, {"WEBHOOK_KEYS", :out_of_range}},
          {%{"WEBHOOK_KEYS" => "#{@old},short-key"}, {"WEBHOOK_KEYS", :out_of_range}},
          {%{"WEBHOOK_KEYS" => "#{@old},#{@new},#{@new}x"}, {"WEBHOOK_KEYS", :too_many_items}},
          {%{"WEBHOOK_KEYS" => String.duplicate("k", 257)}, {"WEBHOOK_KEYS", :out_of_range}},
          {%{"API_KEYS" => ~s(["key-one",""])}, {"API_KEYS", :out_of_range}},
          {%{"API_KEYS" => "[]"}, {"API_KEYS", :too_few_items}},
          {%{"API_KEYS" => ~s({"k": "secret-key-1"})}, {"API_KEYS", :invalid_type}},
          {%{"SIGNING_KEYS__0" => "cookie-old", "SIGNING_KEYS__2" => "cookie-new"},
           {"SIGNING_KEYS", :invalid_type}},
          {%{"WEBHOOK_KEYS" => "vault:secret/data/payments#keys-0123456789abcdef"},
           {"WEBHOOK_KEYS", :invalid_type}}
        ] do
      result = load(env)
      assert codes(result) == [want], "#{inspect(env)}: #{inspect(result)}"
      {:error, e} = result
      text = Exception.message(e) <> inspect(e)

      for {_k, v} <- env, v != "" do
        for key <- v |> String.trim("[") |> String.trim("]") |> String.split(","),
            String.length(key) > 3 do
          refute text =~ key, "#{inspect(env)} printed a key: #{text}"
        end
      end
    end
  end

  test "the message says which key is wrong, by position" do
    {:error, e} = load(%{"WEBHOOK_KEYS" => "#{@old},"})
    assert Exception.message(e) =~ "WEBHOOK_KEYS [out_of_range]: key 2 is empty"
    {:error, e} = load(%{"WEBHOOK_KEYS" => "#{@old},short-key"})
    assert Exception.message(e) =~ "key 2 is 9 characters, shorter than key_min_length 32"
  end

  test "a key set is redacted when inspected or converted to a string" do
    {:ok, env} = load(%{"WEBHOOK_KEYS" => "#{@old},#{@new}"})
    assert inspect(env.webhook_keys) == "#Docuconf.KeySet<2 keys, redacted>"
    assert to_string(env.webhook_keys) == "**redacted**"
    assert "#{env.webhook_keys}" == "**redacted**"
    refute inspect(env) =~ @old
    # Even a raw Erlang term dump does not show the keys.
    refute :io_lib.format(~c"~p", [env.webhook_keys]) |> IO.iodata_to_binary() =~ @old
  end

  test "contains?/2 compares every key" do
    ks = KeySet.new([@old, @new])
    assert KeySet.contains?(ks, @old)
    assert KeySet.contains?(ks, @new)
    refute KeySet.contains?(ks, @old <> "x")
    refute KeySet.contains?(ks, "")
    refute KeySet.contains?(ks, nil)
  end

  test "verify?/2 runs the check against every key, without stopping at a match" do
    ks = KeySet.new([@old, @new])
    body = ~s({"order":"42"})
    sig = :crypto.mac(:hmac, :sha256, @old, body)
    me = self()

    check = fn key ->
      send(me, {:checked, key})
      want = :crypto.mac(:hmac, :sha256, key, body)
      :crypto.hash_equals(want, sig)
    end

    assert KeySet.verify?(ks, check)
    assert_received {:checked, @old}
    assert_received {:checked, @new}
    refute KeySet.verify?(KeySet.new([@new]), check)
    refute KeySet.verify?(nil, check)
  end

  test "declaration rules" do
    for {opts, msg} <- [
          {"secret: false", "a key set is always secret"},
          {"min_keys: 0", "min_keys must be an integer of at least 1"},
          {"min_keys: 3", "max_keys must be an integer of at least min_keys (3)"},
          {"key_min_length: 0", "must be integers of at least 1"},
          {"key_min_length: 9, key_max_length: 8",
           "key_min_length is greater than key_max_length"},
          {"encoding: :json, separator: \";\"", "separator applies only to the csv encoding"},
          {"encoding: :yaml", "encoding must be :csv, :json or :indexed"},
          {"default: \"k\"", "a secret must not have a default"},
          {"examples: [\"k\"]", "a secret must not have examples"},
          {"item_min_length: 3", "unknown option :item_min_length"}
        ] do
      e =
        assert_raise DeclarationError, fn ->
          Code.compile_string("""
          defmodule Docuconf.KeySetTest.Bad#{System.unique_integer([:positive])} do
            use Docuconf, name: "bad"
            env :keys, :key_set, description: "Some keys", #{opts}
          end
          """)
        end

      assert Exception.message(e) =~ msg, "#{opts}: #{Exception.message(e)}"
    end
  end

  test "exports as a secret keySet with its bounds" do
    out = Env.export()
    [_, block] = Regex.run(~r/WEBHOOK_KEYS: \{(.*?)\n\t\t\}/s, out)
    assert block =~ ~s(type: "keySet")
    assert block =~ "secret: true"
    assert block =~ ~s(encoding: "csv")
    assert block =~ ~s(separator: ",")
    assert block =~ "minKeys: 1"
    assert block =~ "maxKeys: 2"
    assert block =~ "keyMinLength: 32"
    assert block =~ "keyMaxLength: 256"
    # env :api_keys, :key_set is secret too.
    [_, api] = Regex.run(~r/API_KEYS: \{(.*?)\n\t\t\}/s, out)
    assert api =~ "secret: true"
    assert api =~ "maxKeys: 3"
  end

  test "contract-first mode returns a KeySet" do
    contract = %{
      "apiVersion" => "docuconf.dev/v1alpha1",
      "kind" => "ConfigContract",
      "metadata" => %{"name" => "svc"},
      "vars" => %{
        "KEYS" => %{
          "type" => "keySet",
          "description" => "Verification keys",
          "secret" => true,
          "minKeys" => 1,
          "maxKeys" => 2,
          "keyMinLength" => 4
        }
      }
    }

    {:ok, values} = Docuconf.Contract.load(contract, env: %{"KEYS" => "abcd,efgh"}, warn: false)
    assert KeySet.keys(values["KEYS"]) == ["abcd", "efgh"]
    refute inspect(values) =~ "abcd"

    assert {:error, %ValidationError{} = e} =
             Docuconf.Contract.load(contract, env: %{"KEYS" => "abcd,ef"}, warn: false)

    assert Exception.message(e) =~ "key 2 is 2 characters, shorter than keyMinLength 4"
  end
end
