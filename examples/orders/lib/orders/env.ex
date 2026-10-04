defmodule Orders.Env do
  @moduledoc "Every input the orders service reads from its environment."
  use Docuconf, name: "orders"

  env(:port, :integer, description: "HTTP listen port", default: 4000, min: 1, max: 65535)

  secret(:database_url, :url,
    description: "Primary Postgres connection string",
    required: true,
    schemes: ["postgres", "ecto"]
  )

  env(:pool_size, :integer, description: "Database connection pool size", default: 10, min: 1)
  env(:checkout_timeout, :duration, description: "Checkout request timeout", default: "15s")

  env(:log_level, {:in, ~w(debug info warning error)},
    description: "Minimum log level",
    default: "info"
  )

  config_file(:pricing,
    format: :json,
    description: "Pricing rules: currency and discount tiers",
    required: true,
    path: "/etc/orders/pricing/pricing.json",
    schema: [
      currency: [type: :string, required: true, pattern: "^[A-Z]{3}$"],
      tiers: [
        type:
          {:list,
           {:map,
            [
              min_total: [type: :pos_integer, required: true],
              percent: [type: :integer, required: true, min: 0, max: 100]
            ]}},
        required: true
      ]
    ]
  )

  tls_file(:serving_tls,
    description: "Certificate the API serves HTTPS with",
    path: "/etc/orders/tls",
    dns_names: ["orders.internal"],
    key_algorithms: [:ecdsa, :rsa],
    min_remaining: "720h"
  )
end
