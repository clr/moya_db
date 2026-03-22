defmodule MoyaDB.API do
  @moduledoc """
  HTTP entry point for MoyaDB. Listens on port 9000 via Bandit.

  Routes are versioned under a path prefix:

      /v0.1  →  MoyaDB.API.V0_1

  Adding a future version is as simple as:

      forward "/v2", to: MoyaDB.API.V2

  JSON request/response bodies are expected and produced for all routes.
  """

  use Plug.Router

  plug Plug.Logger
  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    # Accept any content-type so curl -d '...' works without explicit headers.
    pass: ["*/*"]

  plug :dispatch

  forward "/v0.1", to: MoyaDB.API.V0_1

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
