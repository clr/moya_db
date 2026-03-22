defmodule MoyaDB.API.V0_1 do
  @moduledoc """
  Version 0.1 of the MoyaDB HTTP API.

  All routes are mounted under `/v0.1` by `MoyaDB.API`.

  ## Endpoints

      GET    /v0.1/db/:key   Return the value stored at `key` as JSON.
                             404 if the key does not exist.

      POST   /v0.1/db/:key   Store a value at `key`. The request body is the
                             value (any valid JSON). Idempotent: re-posting the
                             same key replaces its value.
                             200 on success.

      DELETE /v0.1/db/:key   Delete the key-value pair.
                             404 if the key does not exist.

  ## Examples

      # Store
      curl -X POST localhost:9000/v0.1/db/greeting \\
           -H 'Content-Type: application/json' \\
           -d '{"text": "hello"}'

      # Read back
      curl localhost:9000/v0.1/db/greeting

      # Delete
      curl -X DELETE localhost:9000/v0.1/db/greeting
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/db/:key" do
    conn = put_resp_content_type(conn, "application/json")

    case MoyaDB.get(key) do
      {:ok, value} ->
        case Jason.encode(%{key: key, value: value}) do
          {:ok, json} ->
            send_resp(conn, 200, json)

          {:error, _} ->
            send_resp(conn, 422, Jason.encode!(%{error: "stored value is not JSON-serializable"}))
        end

      :error ->
        send_resp(conn, 404, Jason.encode!(%{error: "key not found"}))
    end
  end

  post "/db/:key" do
    conn = put_resp_content_type(conn, "application/json")

    # Plug.Parsers wraps non-object JSON (strings, arrays, numbers) under
    # the "_json" key; unwrap it so we store the actual value.
    value =
      case conn.body_params do
        %{"_json" => v} -> v
        v -> v
      end

    :ok = MoyaDB.put(key, value)
    send_resp(conn, 200, Jason.encode!(%{key: key, value: value}))
  end

  delete "/db/:key" do
    conn = put_resp_content_type(conn, "application/json")

    case MoyaDB.get(key) do
      {:ok, _} ->
        :ok = MoyaDB.delete(key)
        send_resp(conn, 200, Jason.encode!(%{key: key, deleted: true}))

      :error ->
        send_resp(conn, 404, Jason.encode!(%{error: "key not found"}))
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not found"}))
  end
end
