defmodule Orders.Router do
  @moduledoc "The HTTP routes, as an :httpd callback module."
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  def unquote(:do)(request) do
    case {mod(request, :method), mod(request, :request_uri)} do
      {~c"GET", ~c"/healthz"} -> reply(200, "text/plain", "ok")
      {~c"GET", ~c"/config"} -> reply(200, "application/json", JSON.encode!(config()))
      {~c"POST", ~c"/webhooks/payments"} -> payment(request)
      _ -> reply(404, "text/plain", "not found")
    end
  end

  # Payment webhooks, signed with any key in the WEBHOOK_KEYS key set (the
  # README walks through a rotation).
  defp payment(request) do
    keys = Application.fetch_env!(:orders, :env).webhook_keys
    body = mod(request, :entity_body)
    signature = :proplists.get_value(~c"x-signature", mod(request, :parsed_header), ~c"")

    if Orders.Webhook.verify(keys, body, List.to_string(signature)) do
      reply(204, "text/plain", "")
    else
      reply(401, "text/plain", "bad signature")
    end
  end

  # The loaded configuration, typed, with the secrets redacted, set or not.
  defp config do
    Application.fetch_env!(:orders, :env)
    |> Map.from_struct()
    |> Map.put(:database_url, "***")
    |> Map.put(:webhook_keys, "***")
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
