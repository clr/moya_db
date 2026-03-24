defmodule MoyaDB.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:moya_db, :http_port, 9000)

    children = [
      MoyaDB.Store,
      MoyaDB.Cluster,
      {Bandit, plug: MoyaDB.API, scheme: :http, port: port}
    ]

    opts = [strategy: :one_for_one, name: MoyaDB.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
