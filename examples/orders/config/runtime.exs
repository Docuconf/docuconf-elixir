import Config

# Every variable is validated here, at boot. All problems are reported
# together, and written to /dev/termination-log in Kubernetes.
env = Orders.Env.load!()

config :orders, env: env

config :logger,
  level: if(env.log_level == "warn", do: :warning, else: String.to_atom(env.log_level))
