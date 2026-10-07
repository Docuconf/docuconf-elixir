defmodule Docuconf.Test.SecretEnv do
  # Compiled with lib (test/support), before protocols are consolidated, so
  # its generated Inspect implementation is the one users get.
  use Docuconf, name: "secrets"

  env :port, :pos_integer, description: "HTTP listen port", default: 4000
  env :log_level, {:in, [:debug, :info, :warning]}, description: "Log level", default: :info
  secret :secret_key_base, :string, description: "Cookie signing key", required: true
  secret :database_url, :url, description: "Primary database", schemes: ["postgres"]

  text_file :license,
    description: "Licence key",
    secret: true,
    path: "/etc/secrets/license/license.key"
end
