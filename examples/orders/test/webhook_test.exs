defmodule Orders.WebhookTest do
  # The webhook key set: a rotation, step by step, and the key sets that
  # fail at boot.
  use ExUnit.Case, async: true

  @old String.duplicate("o", 32)
  @new String.duplicate("n", 32)
  @body ~s({"order":"42","status":"paid"})
  @base %{"DATABASE_URL" => "postgres://orders:pw@db:5432/orders"}

  defp sign(key), do: :crypto.mac(:hmac, :sha256, key, @body) |> Base.encode16(case: :lower)

  # WEBHOOK_KEYS as the service loads it at boot.
  defp keys(value), do: Orders.Env.load!(env: Map.put(@base, "WEBHOOK_KEYS", value)).webhook_keys

  test "a rotation: each step accepts the key in use" do
    for {value, accepts} <- [
          {@old, %{@old => true, @new => false}},
          {"#{@old},#{@new}", %{@old => true, @new => true}},
          {@new, %{@old => false, @new => true}}
        ],
        ks = keys(value),
        {key, want} <- accepts do
      assert Orders.Webhook.verify(ks, @body, sign(key)) == want
    end
  end

  test "an unsigned, malformed or foreign signature is rejected, and everything without keys" do
    ks = keys(@old)
    refute Orders.Webhook.verify(ks, @body, nil)
    refute Orders.Webhook.verify(ks, @body, "not hex")
    refute Orders.Webhook.verify(ks, @body, sign(String.duplicate("x", 32)))
    refute Orders.Webhook.verify(ks, @body <> " ", sign(@old))
    refute Orders.Webhook.verify(nil, @body, sign(@old))
  end

  test "optional, and secret in the config's inspect output" do
    assert Orders.Env.load!(env: @base).webhook_keys == nil
    env = Orders.Env.load!(env: Map.put(@base, "WEBHOOK_KEYS", "#{@old},#{@new}"))
    refute inspect(env) =~ @old
  end

  test "an empty or truncated key, or a third key, fails at boot without printing a key" do
    for {value, code} <- [
          {"#{@old},", :out_of_range},
          {"#{@old},#{String.slice(@new, 0, 10)}", :out_of_range},
          {"#{@old},#{@new},#{String.duplicate("x", 32)}", :too_many_items}
        ] do
      assert {:error, e} = Orders.Env.load(env: Map.put(@base, "WEBHOOK_KEYS", value))
      assert Enum.map(e.violations, &{&1.input, &1.code}) == [{"WEBHOOK_KEYS", code}]
      message = Exception.message(e)
      refute message =~ @old
      refute message =~ String.slice(@new, 0, 10)
    end
  end
end
