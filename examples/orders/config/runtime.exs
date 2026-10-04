import Config

# Every variable and file is validated here, at boot; all problems are
# reported together and written to /dev/termination-log in Kubernetes.
env = Orders.Env.load!()

config :orders, Orders.Repo,
  url: env.database_url,
  pool_size: env.pool_size

config :orders, :http, port: env.port
config :orders, :checkout_timeout_ms, env.checkout_timeout
config :orders, :pricing, env.pricing.data

if tls = env.serving_tls do
  config :orders, :https, certfile: tls.data.certfile, keyfile: tls.data.keyfile
end

config :logger, level: String.to_existing_atom(env.log_level)
