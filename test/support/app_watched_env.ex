defmodule Docuconf.Test.AppWatchedEnv do
  @moduledoc false
  # Compiled into the :docuconf application in tests, so the watcher check
  # waits for that application to start rather than for a grace period.
  use Docuconf, name: "app-watched"

  text_file :motd,
    description: "Message of the day",
    path: "/etc/svc/motd/motd.txt",
    required: false,
    reload: :watch
end
