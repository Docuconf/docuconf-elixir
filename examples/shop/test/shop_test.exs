defmodule ShopTest do
  # The README's test matrix. Every case starts from the base env and a
  # fresh, empty file root (each test gets its own tmp_dir).
  use ExUnit.Case, async: true

  alias Docuconf.ValidationError

  @moduletag :tmp_dir

  @database_url "postgres://shop@db:5432/shop"
  @key_file "etc/shop/webhooks/signing.key"

  defp load(env, root) do
    base = %{"DATABASE_URL" => @database_url, "DOCUCONF_FILE_ROOT" => root}
    Shop.load(env: Map.merge(base, env), termination_log: false, warn: false)
  end

  # The line the app prints for a valid configuration.
  defp line(env, root) do
    assert {:ok, values} = load(env, root)
    Shop.summary(values)
  end

  # Every problem as {input, code, message}. The report never prints the
  # secret DATABASE_URL.
  defp problems(env, root) do
    assert {:error, %ValidationError{violations: vs} = e} = load(env, root)
    refute Exception.message(e) =~ @database_url
    Enum.map(vs, &{&1.input, &1.code, &1.message})
  end

  test "1. web", %{tmp_dir: root} do
    env = %{"DOCUCONF_ROLE" => "web", "ALLOWED_ORIGINS" => "https://shop.example"}

    assert line(env, root) == "shop web: port 8080, origins https://shop.example"
  end

  test "2. worker: it needs no ALLOWED_ORIGINS", %{tmp_dir: root} do
    env = %{"DOCUCONF_ROLE" => "worker", "QUEUES" => "default,mail"}

    assert {:ok, values} = load(env, root)

    # The printed queues are the typed list, not the raw variable.
    assert values["QUEUES"] == ["default", "mail"]
    assert values["ALLOWED_ORIGINS"] == nil
    assert Shop.summary(values) == "shop worker: queues default,mail, webhooks off"
  end

  test "3. web without ALLOWED_ORIGINS", %{tmp_dir: root} do
    env = %{"DOCUCONF_ROLE" => "web"}

    assert [{"ALLOWED_ORIGINS", :missing_required, _}] = problems(env, root)
  end

  test "4. no role: DOCUCONF_ROLE is missing, and nothing else", %{tmp_dir: root} do
    assert [{"DOCUCONF_ROLE", :missing_required, _}] = problems(%{"QUEUES" => "default"}, root)
  end

  test "5. an unknown role: DOCUCONF_ROLE only", %{tmp_dir: root} do
    assert [{"DOCUCONF_ROLE", :not_in_enum, _}] = problems(%{"DOCUCONF_ROLE" => "cron"}, root)
  end

  test "6. JSON logs need LOG_SCHEMA_URL", %{tmp_dir: root} do
    env = %{"DOCUCONF_ROLE" => "worker", "QUEUES" => "default", "LOG_FORMAT" => "json"}

    assert [{"LOG_SCHEMA_URL", :missing_required, message}] = problems(env, root)
    assert message =~ ~s(is required when LOG_FORMAT is "json")
  end

  test "7. JSON logs with LOG_SCHEMA_URL", %{tmp_dir: root} do
    env = %{
      "DOCUCONF_ROLE" => "worker",
      "QUEUES" => "default",
      "LOG_FORMAT" => "json",
      "LOG_SCHEMA_URL" => "https://logs.example/v1.json"
    }

    assert {:ok, values} = load(env, root)
    assert values["LOG_SCHEMA_URL"] == "https://logs.example/v1.json"
    assert Shop.summary(values) == "shop worker: queues default, webhooks off"
  end

  test "8. webhooks on without the signing key", %{tmp_dir: root} do
    env = %{"DOCUCONF_ROLE" => "worker", "QUEUES" => "default", "WEBHOOKS_ENABLED" => "true"}

    assert [{"webhook-signing-key", :file_missing, message}] = problems(env, root)
    assert message =~ ", and is required when WEBHOOKS_ENABLED is true"
  end

  test "9. webhooks on with the signing key", %{tmp_dir: root} do
    key = String.duplicate("k", 40)
    path = Path.join(root, @key_file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, key)
    env = %{"DOCUCONF_ROLE" => "worker", "QUEUES" => "default", "WEBHOOKS_ENABLED" => "true"}

    assert {:ok, values} = load(env, root)
    assert values["webhook-signing-key"].data == key
    assert Shop.summary(values) == "shop worker: queues default, webhooks on"
    # The key is secret: inspecting the values does not show it.
    refute inspect(values) =~ key
  end

  test "10. web with WEBHOOKS_ENABLED: the key file is the worker's", %{tmp_dir: root} do
    env = %{
      "DOCUCONF_ROLE" => "web",
      "ALLOWED_ORIGINS" => "https://shop.example",
      "WEBHOOKS_ENABLED" => "true"
    }

    assert line(env, root) == "shop web: port 8080, origins https://shop.example"
  end

  test "11. the otel@1 fragment's variables are checked at boot", %{tmp_dir: root} do
    env = %{
      "DOCUCONF_ROLE" => "web",
      "ALLOWED_ORIGINS" => "https://shop.example",
      "OTEL_EXPORTER_OTLP_PROTOCOL" => "carrier-pigeon"
    }

    assert [{"OTEL_EXPORTER_OTLP_PROTOCOL", :not_in_enum, _}] = problems(env, root)
  end
end
