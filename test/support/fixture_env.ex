defmodule Docuconf.Test.FixtureEnv do
  @moduledoc false
  # The shared export fixture (docuconf-go conformance/export/fixture.yaml),
  # declared with `use Docuconf`. Its export must match
  # conformance/export/golden.cue as data (SPEC §11.2 item 3, §12); see
  # test/conformance_export_test.exs.
  use Docuconf, name: "docuconf-fixture", app_version: "1.0.0"

  @doc """
  Service name, used in logs and metrics

  Lower case, as a DNS label allows.
  """
  env :app_name, :string,
    default: "orders",
    min_length: 2,
    max_length: 40,
    pattern: ~r/^[a-z][a-z0-9-]*$/,
    group: "general",
    examples: ["orders", "billing"],
    config_key: "App:Name"

  @doc "Primary Postgres connection string"
  secret :database_url, :url,
    required: true,
    schemes: ["postgres", "postgresql"],
    max_length: 2048,
    group: "database"

  @doc "HTTP listen port"
  env :port, :integer, default: 8080, min: 1, max: 65535

  @doc "Fraction of requests traced"
  env :trace_ratio, :float, default: 0.25, min: 0, max: 1

  @doc "Serve the debug endpoints"
  env :debug, :boolean, default: false

  @doc "Upstream request timeout"
  env :request_timeout, :duration, default: "1m30s", min: "1s", max: "5m"

  @doc "Minimum log level"
  env :log_level, {:in, ~w(debug info warn error)}, default: "info"

  @doc "CORS origins allowed to call the API"
  env :allowed_origins, {:list, :string},
    min_items: 1,
    max_items: 5,
    item_min_length: 1,
    item_max_length: 255,
    separator: ";"

  @doc "Shards this instance owns"
  env :shards, {:list, :integer}, item_min: 0, item_max: 1023

  @doc "Keys that verify webhook signatures"
  secret :webhook_keys, :key_set, key_min_length: 32, key_max_length: 256

  @doc "Per-client rate limits"
  env :rate_limits, :json,
    default: %{"perMinute" => 60},
    max_length: 1024,
    schema: [
      perMinute: [type: :pos_integer, required: true],
      burst: [type: :non_neg_integer]
    ]

  @doc "Port the service used to listen on"
  env :old_port, :integer, deprecated: [message: "Use PORT instead", replaced_by: :port]

  @doc "Password of the partner keystore"
  secret :partner_password, :string

  @settings [
    name: [type: :string, required: true, min_length: 1],
    replicas: [type: :pos_integer, required: true],
    tags: [type: {:list, :string}]
  ]

  @doc "Application settings"
  config_file :settings,
    format: :json,
    required: true,
    path: "/etc/app/settings/settings.json",
    path_env: "SETTINGS_FILE",
    reload: :watch,
    max_size: 65536,
    group: "general",
    schema: @settings

  @doc "Routing rules"
  config_file :rules,
    format: :yaml,
    decoder: &Docuconf.YAML.decode/1,
    path: "/etc/app/rules/rules.yaml",
    schema: @settings

  @doc "Feature defaults"
  config_file :flags,
    format: :toml,
    decoder: &Docuconf.TOML.decode/1,
    path: "/etc/app/flags/flags.toml",
    schema: @settings

  @doc "Certificate the service serves HTTPS with"
  tls_file :serving_tls,
    path: "/etc/app/tls",
    reload: :watch,
    dns_names: ["app.example.test", "api.example.test"],
    key_algorithms: [:ecdsa, :ed25519],
    min_remaining: "720h",
    require_ca: true

  @doc "CAs the service trusts"
  ca_bundle_file :trust, path: "/etc/app/trust/bundle.pem", min_certificates: 2

  @doc "Client certificate for the partner API"
  keystore_file :partner,
    format: :pkcs12,
    path: "/etc/app/partner/keystore.p12",
    password_var: :partner_password

  @doc "Licence key"
  text_file :licence,
    path: "/etc/app/licence/licence.key",
    min_length: 8,
    max_length: 64,
    pattern: "^[A-Z0-9-]+\\n?$"

  @doc "GeoIP database"
  binary_file :geoip,
    path: "/data/geoip/geoip.mmdb",
    max_size: 134_217_728,
    deprecated: [message: "Use geo-db instead", replaced_by: :geo_db]

  @doc "City-level location database"
  binary_file :geo_db, path: "/data/geo-db/geo.mmdb"
end
