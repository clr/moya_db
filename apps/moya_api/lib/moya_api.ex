defmodule MoyaApi do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/kv", to: MoyaApiKvRouter

  match _ do
    send_resp(conn, 404, "Moya did not understand")
  end
end
