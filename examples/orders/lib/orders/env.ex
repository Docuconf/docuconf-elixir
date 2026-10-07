defmodule Orders.Env do
  @moduledoc "Every environment variable the orders service reads."
  use Docuconf, name: "orders"

  env :port, :integer, description: "HTTP listen port", default: 8080, min: 1, max: 65535

  # Atom values come back as atoms, ready for Logger.
  env :log_level, {:in, [:debug, :info, :warning, :error]},
    description: "Minimum log level",
    default: :info

  # A secret: docuconf never prints its value (not in errors, and not when
  # Orders.Env is inspected or logged), and the contract tells the platform
  # to supply it from a Kubernetes Secret.
  secret :database_url, :url,
    description: "Postgres connection string",
    required: true,
    schemes: ["postgres"]

  env :allowed_origins, {:list, :string},
    description: "Origins allowed to call the API (CORS)",
    min_items: 1,
    default: ["http://localhost:3000"]

  env :request_timeout, :duration,
    description: "Time limit for one request",
    min: "1s",
    max: "5m",
    default: "30s"

  env :worker_count, :integer,
    description: "Order processing workers",
    min: 1,
    max: 64,
    default: 4
end
