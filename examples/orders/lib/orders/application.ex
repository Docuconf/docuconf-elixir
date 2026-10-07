defmodule Orders.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    env = Application.fetch_env!(:orders, :env)

    httpd = [
      port: env.port,
      server_name: ~c"orders",
      server_root: String.to_charlist(System.tmp_dir!()),
      document_root: String.to_charlist(System.tmp_dir!()),
      modules: [Orders.Router]
    ]

    children = [
      %{id: :httpd, start: {:inets, :start, [:httpd, httpd, :stand_alone]}, type: :supervisor}
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one) do
      IO.puts("orders listening on port #{env.port}")
      {:ok, pid}
    end
  end
end
