import Config

# Every variable is validated here, at boot. All problems are reported
# together, the process exits with status 1, and the report is written to
# /dev/termination-log in Kubernetes.
env = Orders.Env.load!()

config :orders, env: env
config :logger, level: env.log_level
