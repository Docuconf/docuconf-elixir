defmodule Orders.Router do
  @moduledoc "The HTTP routes, as an :httpd callback module."
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  def unquote(:do)(request) do
    case {mod(request, :method), mod(request, :request_uri)} do
      {~c"GET", ~c"/healthz"} -> reply(200, "text/plain", "ok")
      {~c"GET", ~c"/config"} -> reply(200, "application/json", JSON.encode!(config()))
      _ -> reply(404, "text/plain", "not found")
    end
  end

  # The loaded configuration, typed, with the secret redacted.
  defp config do
    Application.fetch_env!(:orders, :env)
    |> Map.from_struct()
    |> Map.put(:database_url, "***")
  end

  defp reply(code, type, body) do
    head = [
      code: code,
      content_type: String.to_charlist(type),
      content_length: body |> byte_size() |> Integer.to_charlist()
    ]

    {:proceed, [response: {:response, head, body}]}
  end
end
