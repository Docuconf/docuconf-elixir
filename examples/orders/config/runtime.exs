import Config

# Every variable is validated here, at boot. All problems are reported
# together, the process exits with status 1, and the report is written to
# /dev/termination-log in Kubernetes. Tests load Orders.Env from maps of
# their own instead (Orders.Env.load(env: %{...})).
if config_env() != :test do
  env = Orders.Env.load!()

  config :orders, env: env
  config :logger, level: env.log_level
end
