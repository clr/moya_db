defmodule MoyaApiKvRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  # List the keys in a bucket.
  get "/:bucket" do
    send_resp(conn, 200, "value")
  end

  # Read a value.
  get "/:bucket/:key" do
    send_resp(conn, 200, "value")
   #  MoyaPolicy.Kv.apply({:get, bucket, key})
  end

  # Create a value.
  put "/:bucket/:key" do
    send_resp(conn, 200, "value")
  end

  # Delete a value.
  delete "/:bucket/:key" do
    send_resp(conn, 200, "value")
  end

  match _ do
    send_resp(conn, 404, "Moya did not understand")
  end
end
