defmodule Docuconf.ConditionalTest do
  # requiredIf (SPEC §4.2.1), roles (SPEC §4.9) and includes (SPEC §4.8) in
  # contract-first mode, beyond the shared suite: the messages, role
  # narrowing and the contracts the reader refuses.
  use ExUnit.Case, async: true

  alias Docuconf.{Contract, DeclarationError, ValidationError}

  @moduletag :tmp_dir

  @conditional %{
    "apiVersion" => "docuconf.dev/v1alpha1",
    "kind" => "ConfigContract",
    "metadata" => %{"name" => "relay"},
    "vars" => %{
      "APP_ENV" => %{"type" => "string", "description" => "Profile name", "default" => "dev"},
      "TLS_ENABLED" => %{"type" => "bool", "description" => "Serve HTTPS", "default" => false},
      "LOG_FORMAT" => %{
        "type" => "enum",
        "description" => "Log output format",
        "values" => ["text", "json"],
        "default" => "text"
      },
      "PORT" => %{"type" => "int", "description" => "Port to listen on", "default" => 8080},
      "CA_SUBJECT" => %{
        "type" => "string",
        "description" => "Subject of the client CA",
        "requiredIf" => %{"TLS_ENABLED" => true}
      },
      "LOG_SCHEMA_URL" => %{
        "type" => "url",
        "description" => "Schema the logs follow",
        "requiredIf" => %{"LOG_FORMAT" => "json"}
      },
      "ACME_EMAIL" => %{
        "type" => "string",
        "description" => "Contact for certificate renewal",
        "requiredIf" => %{"PORT" => 443}
      }
    },
    "files" => %{
      "allowlist" => %{
        "type" => "text",
        "description" => "Client names allowed over TLS",
        "path" => "/etc/relay/allowlist/allow.txt",
        "requiredIf" => %{"TLS_ENABLED" => true}
      }
    },
    "profiles" => %{
      "selector" => "APP_ENV",
      "default" => "dev",
      "defaults" => %{"prod" => %{"TLS_ENABLED" => true}}
    }
  }

  @roles %{
    "apiVersion" => "docuconf.dev/v1alpha1",
    "kind" => "ConfigContract",
    "metadata" => %{"name" => "shop"},
    "roles" => ["web", "worker"],
    "vars" => %{
      "DOCUCONF_ROLE" => %{
        "type" => "enum",
        "description" => "The role this workload runs",
        "required" => true,
        "values" => ["web", "worker"]
      },
      "DATABASE_URL" => %{
        "type" => "string",
        "description" => "Database connection string",
        "required" => true
      },
      "ALLOWED_ORIGINS" => %{
        "type" => "list",
        "items" => "string",
        "description" => "Origins the web server accepts",
        "required" => true,
        "roles" => ["web"]
      },
      "QUEUES" => %{
        "type" => "list",
        "items" => "string",
        "description" => "Queues the worker takes jobs from",
        "required" => true,
        "roles" => ["worker"]
      }
    },
    "files" => %{
      "robots" => %{
        "type" => "text",
        "description" => "The robots.txt the web server serves",
        "path" => "/etc/shop/robots/robots.txt",
        "required" => true,
        "roles" => ["web"]
      }
    }
  }

  defp load(contract, env, root) do
    env = Map.put(env, "DOCUCONF_FILE_ROOT", root)
    Contract.load(contract, env: env, termination_log: false, warn: false)
  end

  defp violations({:error, %ValidationError{violations: vs}}),
    do: vs |> Enum.map(&{&1.input, &1.code, &1.message}) |> Enum.sort()

  defp problems(contract) do
    assert {:error, %DeclarationError{problems: ps}} = Contract.parse(contract)
    Enum.join(ps, "\n")
  end

  describe "requiredIf" do
    test "conditions off: the inputs are optional", %{tmp_dir: root} do
      assert {:ok, values} = load(@conditional, %{}, root)
      assert values["CA_SUBJECT"] == nil
      assert values["allowlist"] == nil
    end

    test "each message names the condition, the value as JSON", %{tmp_dir: root} do
      env = %{"TLS_ENABLED" => "true", "LOG_FORMAT" => "json", "PORT" => "443"}
      path = Path.join(root, "etc/relay/allowlist/allow.txt")
      file_message = "#{path} not found, and is required when TLS_ENABLED is true"

      assert violations(load(@conditional, env, root)) == [
               {"ACME_EMAIL", :missing_required, "is required when PORT is 443"},
               {"CA_SUBJECT", :missing_required, "is required when TLS_ENABLED is true"},
               {"LOG_SCHEMA_URL", :missing_required, ~s(is required when LOG_FORMAT is "json")},
               {"allowlist", :file_missing, file_message}
             ]
    end

    test "the inputs load when set", %{tmp_dir: root} do
      path = Path.join(root, "etc/relay/allowlist/allow.txt")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "billing\n")
      env = %{"TLS_ENABLED" => "true", "CA_SUBJECT" => "CN=Client CA"}

      assert {:ok, values} = load(@conditional, env, root)
      assert values["CA_SUBJECT"] == "CN=Client CA"
      assert values["allowlist"].data == "billing\n"
    end

    test "a condition holds on a default and on the selected profile", %{tmp_dir: root} do
      on_default = put_in(@conditional, ["vars", "PORT", "default"], 443)
      assert [{"ACME_EMAIL", :missing_required, _}] = violations(load(on_default, %{}, root))

      prod = %{"APP_ENV" => "prod"}

      assert [{"CA_SUBJECT", :missing_required, _}, {"allowlist", :file_missing, _}] =
               violations(load(@conditional, prod, root))

      # The environment beats the profile.
      assert {:ok, _} = load(@conditional, Map.put(prod, "TLS_ENABLED", "false"), root)
    end

    test "a condition variable with a violation makes nothing required", %{tmp_dir: root} do
      result = load(@conditional, %{"TLS_ENABLED" => "yes"}, root)
      assert [{"TLS_ENABLED", :invalid_type, _}] = violations(result)
    end

    test "an int condition, where true is not 1", %{tmp_dir: root} do
      contract =
        @conditional
        |> put_in(["vars", "FLAGS"], %{"type" => "int", "description" => "Flag count"})
        |> put_in(["vars", "CA_SUBJECT", "requiredIf"], %{"FLAGS" => 1})

      assert {:ok, _} = load(contract, %{"FLAGS" => "2"}, root)

      assert [{"CA_SUBJECT", :missing_required, "is required when FLAGS is 1"}] =
               violations(load(contract, %{"FLAGS" => "1"}, root))

      on_bool = put_in(contract, ["vars", "CA_SUBJECT", "requiredIf"], %{"FLAGS" => true})

      assert problems(on_bool) =~
               "env CA_SUBJECT: requiredIf: FLAGS is true is not a value FLAGS can have"
    end

    test "the reader refuses a bad condition" do
      cases = [
        {%{"TLS_ENABLED" => true, "PORT" => 443}, " must name one variable and its value"},
        {%{"TLS_ENABLED" => 1.5}, " must name one variable and a string, int or bool value"},
        {%{"tls" => true}, " must name one variable and a string, int or bool value"},
        {%{"NOPE" => true}, ~s( must name another declared variable, not "NOPE")},
        {%{"CA_SUBJECT" => "x"}, ~s( must name another declared variable, not "CA_SUBJECT")},
        {%{"TLS_ENABLED" => "true"}, ~s(: TLS_ENABLED is "true" is not a value TLS_ENABLED)},
        {%{"LOG_FORMAT" => "xml"}, ~s(: LOG_FORMAT is "xml" is not a value LOG_FORMAT can have)},
        {%{"TIMEOUT" => "1m"}, " names TIMEOUT, which is not a plain string, int, bool or enum"},
        {%{"TOKEN" => "x"}, " names TOKEN, which is not a plain string, int, bool or enum"}
      ]

      timeout = %{"type" => "duration", "description" => "Request timeout"}
      token = %{"type" => "string", "description" => "Partner token", "secret" => true}

      vars = Map.merge(@conditional["vars"], %{"TIMEOUT" => timeout, "TOKEN" => token})
      base = Map.put(@conditional, "vars", vars)

      for {condition, message} <- cases do
        text = problems(put_in(base, ["vars", "CA_SUBJECT", "requiredIf"], condition))
        assert text =~ "env CA_SUBJECT: requiredIf" <> message
      end
    end

    test "the reader refuses requiredIf on a required, defaulted or deprecated input" do
      required = put_in(@conditional, ["vars", "CA_SUBJECT", "required"], true)
      defaulted = put_in(@conditional, ["vars", "CA_SUBJECT", "default"], "CN=x")
      gone = %{"message" => "Gone"}
      deprecated = put_in(@conditional, ["vars", "CA_SUBJECT", "deprecated"], gone)
      file = put_in(@conditional, ["files", "allowlist", "required"], true)

      assert problems(required) =~
               "env CA_SUBJECT: an input with requiredIf is neither required nor has a default"

      assert problems(defaulted) =~
               "env CA_SUBJECT: an input with requiredIf is neither required nor has a default"

      assert problems(deprecated) =~
               "env CA_SUBJECT: a conditionally required input cannot be deprecated"

      assert problems(file) =~
               "file allowlist: an input with requiredIf is neither required nor has a default"
    end
  end

  describe "roles" do
    test "an input of another role is optional", %{tmp_dir: root} do
      env = %{"DOCUCONF_ROLE" => "worker", "DATABASE_URL" => "db", "QUEUES" => "default,mail"}
      assert {:ok, values} = load(@roles, env, root)
      assert values["QUEUES"] == ["default", "mail"]
      assert values["ALLOWED_ORIGINS"] == nil
      assert values["robots"] == nil

      result = load(@roles, Map.delete(env, "QUEUES"), root)
      assert [{"QUEUES", :missing_required, _}] = violations(result)
    end

    test "a role's own inputs are required", %{tmp_dir: root} do
      result = load(@roles, %{"DOCUCONF_ROLE" => "web", "DATABASE_URL" => "db"}, root)
      assert [{"ALLOWED_ORIGINS", :missing_required, _}, {"robots", :file_missing, _}] =
               violations(result)
    end

    test "with no role, or an unknown one, the role is the one problem", %{tmp_dir: root} do
      no_role = load(@roles, %{"DATABASE_URL" => "db"}, root)
      assert [{"DOCUCONF_ROLE", :missing_required, _}] = violations(no_role)

      unknown = load(@roles, %{"DOCUCONF_ROLE" => "cron", "DATABASE_URL" => "db"}, root)
      assert [{"DOCUCONF_ROLE", :not_in_enum, _}] = violations(unknown)
    end

    test "a condition applies only in the input's roles", %{tmp_dir: root} do
      cdn_host = %{
        "type" => "string",
        "description" => "CDN host name",
        "requiredIf" => %{"CDN" => true},
        "roles" => ["worker"]
      }

      contract =
        @roles
        |> put_in(["vars", "CDN"], %{"type" => "bool", "description" => "Serve from a CDN"})
        |> put_in(["vars", "CDN_HOST"], cdn_host)

      env = %{"CDN" => "true", "DATABASE_URL" => "db", "QUEUES" => "q"}
      worker = load(contract, Map.put(env, "DOCUCONF_ROLE", "worker"), root)
      want = [{"CDN_HOST", :missing_required, "is required when CDN is true"}]
      assert violations(worker) == want

      # With no role, CDN_HOST is not required either.
      assert [{"DOCUCONF_ROLE", :missing_required, _}] = violations(load(contract, env, root))
    end

    test "the reader refuses bad roles" do
      not_one_of = "env QUEUES: role cron is not one of the contract's roles, web, worker"
      role_var = "env DOCUCONF_ROLE: a contract with roles declares it as a required enum"

      cases = [
        {Map.put(@roles, "roles", []), "roles must be a list of at least one role name"},
        {Map.put(@roles, "roles", "web"), "roles must be a list of at least one role name"},
        {Map.put(@roles, "roles", ["web", "Web"]), ~s(roles: role "Web" must be a DNS label)},
        {Map.put(@roles, "roles", ["web", "worker", "web"]), "roles: role web is listed twice"},
        {put_in(@roles, ["vars", "QUEUES", "roles"], ["cron"]), not_one_of},
        {put_in(@roles, ["files", "robots", "roles"], []), "file robots: roles must be a list"},
        {put_in(@roles, ["vars", "DOCUCONF_ROLE", "values"], ["worker", "web"]), role_var},
        {put_in(@roles, ["vars", "DOCUCONF_ROLE", "roles"], ["web"]), role_var},
        {update_in(@roles, ["vars"], &Map.delete(&1, "DOCUCONF_ROLE")), role_var},
        {Map.delete(@roles, "roles"), "env QUEUES: has roles, but the contract declares none"}
      ]

      for {contract, message} <- cases do
        assert problems(contract) =~ message
      end
    end
  end

  describe "includes" do
    test "are read and exposed on the declaration" do
      contract = Map.put(@roles, "includes", ["otel@1", "go-runtime@1"])
      assert {:ok, decl} = Contract.parse(contract)
      assert decl.includes == ["otel@1", "go-runtime@1"]
      assert decl.roles == ["web", "worker"]
      assert {:ok, %{includes: [], roles: nil}} = Contract.parse(@conditional)
    end

    test "the reader refuses a bad list" do
      assert problems(Map.put(@roles, "includes", "otel@1")) =~
               "includes must be a list of fragment names, such as otel@1"

      assert problems(Map.put(@roles, "includes", ["otel"])) =~
               ~s(includes: "otel" is not a fragment name, name@major)

      assert problems(Map.put(@roles, "includes", ["otel@1", "otel@1"])) =~
               "includes: otel@1 is listed twice"
    end
  end
end
