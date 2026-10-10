defmodule Docuconf.ReloadStatus do
  @moduledoc """
  The reload status of one `reload: :watch` file input (SPEC §4.6.2), from
  `Docuconf.Watcher.status/2`:

    * `generation` - 1 when the watcher starts (at boot), plus one per
      accepted reload;
    * `last_reload` - when the last reload was accepted (`DateTime`, UTC),
      or `nil` before the first one;
    * `last_rejected` - the last change that failed its checks, as a
      `Docuconf.RejectedReload`, or `nil`. An accepted reload clears it.

  It never holds file content, so it can be served from a health check or
  exported as a metric. It encodes with Elixir's `JSON`:

      JSON.encode!(Docuconf.Watcher.status(MyApp.Files))
      #=> {"serving_tls":{"generation":2,"last_reload":"2026-10-10T13:44:18.526735Z","last_rejected":null}}
  """

  @derive JSON.Encoder
  @enforce_keys [:generation]
  defstruct generation: 1, last_reload: nil, last_rejected: nil

  @type t :: %__MODULE__{
          generation: pos_integer(),
          last_reload: DateTime.t() | nil,
          last_rejected: Docuconf.RejectedReload.t() | nil
        }
end

defmodule Docuconf.RejectedReload do
  @moduledoc """
  A change to a watched file that failed its boot checks, so the previous
  value stayed current: when it was seen, the input's contract name, and the
  violation codes. Never the content.
  """

  @derive JSON.Encoder
  @enforce_keys [:time, :input, :codes]
  defstruct [:time, :input, :codes]

  @type t :: %__MODULE__{
          time: DateTime.t(),
          input: String.t(),
          codes: [Docuconf.Violation.code()]
        }
end
