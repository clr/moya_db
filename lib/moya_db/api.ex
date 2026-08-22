defmodule MoyaDB.API do
  @moduledoc """
  HTTP entry point for MoyaDB. Listens on port 9000 via Bandit.

  Routes are grouped by module first, then versioned:

      /db/v0.1  →  MoyaDB.API.V0_1

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

  forward "/db/v0.1", to: MoyaDB.API.V0_1

  @spec handle_request(map()) :: %{status: integer(), headers: [{binary(), binary()}], body: term()}
  def handle_request(%{path: path} = request) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["db", "v0.1" | rest] ->
        MoyaDB.API.V0_1.handle_request(%{request | path: "/" <> Enum.join(rest, "/")})

      _ ->
        %{
          status: 404,
          headers: [{"content-type", "application/json; charset=utf-8"}],
          body: %{error: "not found"}
        }
    end
  end

  def handle_request(_request) do
    %{
      status: 400,
      headers: [{"content-type", "application/json; charset=utf-8"}],
      body: %{error: "invalid request"}
    }
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
