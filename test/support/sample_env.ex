defmodule Docuconf.Test.SampleEnv do
  @moduledoc false
  # Every variable type and every file type, for the export golden test.
  use Docuconf, name: "sample-gateway"

  secret :database_url, :url,
    description: "Primary Postgres connection string",
    required: true,
    schemes: ["postgres", "postgresql"]

  env :port, :integer, description: "HTTP listen port", default: 8080, min: 1, max: 65535
  env :gomemlimit, :integer, description: "Soft memory limit, in bytes", min: 1
  env :sample_rate, :float, description: "Fraction of requests traced", default: 0.25, min: 0, max: 1
  env :debug, :boolean, description: "Verbose request logging", default: false

  env :request_timeout, :duration,
    description: "Upstream request timeout",
    default: "30s",
    min: "1s",
    max: "5m"

  env :public_url, :url, description: "Externally visible base URL", required: true, schemes: ["https"]

  env :log_level, {:in, ~w(debug info warn error)},
    description: "Minimum log level emitted",
    default: "info",
    group: "logging"

  env :allowed_origins, {:list, :string},
    description: "CORS origins allowed to call the API",
    required: true,
    min_items: 1,
    max_items: 10

  env :worker_ports, {:list, :integer}, description: "Ports the workers bind", separator: ";"

  env :rate_limits, :json,
    description: "Default per-client rate limits",
    schema: [
      per_minute: [type: :pos_integer, required: true],
      burst: [type: :non_neg_integer]
    ]

  env :region, :string,
    description: "Cloud region the service runs in",
    required: true,
    examples: ["eu-west-1"],
    min_length: 4,
    max_length: 32,
    pattern: ~r/^[a-z]{2}-[a-z]+-[0-9]$/

  secret :keystore_password, :string, description: "Password for the partner keystore", min_length: 1

  config_file :routes,
    format: :json,
    description: "Routing table: path prefixes and their upstreams",
    required: true,
    path: "/etc/gateway/routes/routes.json",
    path_env: "ROUTES_FILE",
    max_size: 65536,
    schema: [
      routes: [
        type:
          {:list,
           {:map,
            [
              match: [type: :string, required: true, pattern: "^/"],
              upstream: [type: :string, required: true, pattern: "^https?://"],
              timeout: [type: :string]
            ]}},
        required: true,
        min_items: 1
      ]
    ]

  tls_file :serving_tls,
    description: "Certificate the gateway serves HTTPS with",
    required: true,
    path: "/etc/gateway/tls",
    dns_names: ["gateway.internal", "api.example.com"],
    key_algorithms: [:ecdsa, :rsa],
    min_remaining: "720h",
    require_ca: true

  ca_bundle_file :upstream_ca,
    description: "Private CAs the gateway trusts for upstream TLS",
    path: "/etc/gateway/ca/bundle.pem",
    path_env: "SSL_CERT_FILE"

  keystore_file :partner_keystore,
    format: :pkcs12,
    description: "Client certificate for mTLS to the partner API",
    path: "/etc/gateway/partner/keystore.p12",
    password_var: :keystore_password

  text_file :license,
    description: "Gateway licence key",
    required: true,
    path: "/etc/gateway/license/license.key",
    pattern: "^[A-Z0-9]{5}(-[A-Z0-9]{5}){3}\\n?$"

  binary_file :geoip,
    description: "GeoIP database for country-based routing",
    path: "/data/geoip/GeoLite2-City.mmdb",
    max_size: 134_217_728
end
