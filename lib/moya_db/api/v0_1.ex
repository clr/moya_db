defmodule MoyaDB.API.V0_1 do
  @moduledoc """
  Version 0.1 of the MoyaDB HTTP API.

  All routes are mounted under `/db/v0.1` by `MoyaDB.API`.

  ## Endpoints

      GET    /db/v0.1/metrics
                             Return rolling inbound query and latency metrics.

      GET    /db/v0.1/:key   Return the value stored at `key` as JSON.
                             404 if the key does not exist.

      POST   /db/v0.1/:key   Store a value at `key`. The request body is the
                             value (any valid JSON). Idempotent: re-posting the
                             same key replaces its value.
                             200 on success.

      DELETE /db/v0.1/:key   Delete the key-value pair.
                             404 if the key does not exist.

  ## Examples

      # Store
      curl -X POST localhost:9000/db/v0.1/greeting \\
           -H 'Content-Type: application/json' \\
           -d '{"text": "hello"}'

      # Read back
      curl localhost:9000/db/v0.1/greeting

      # Delete
      curl -X DELETE localhost:9000/db/v0.1/greeting
  """

  use Plug.Router

  @json_headers [{"content-type", "application/json; charset=utf-8"}]

  plug :put_request_start
  plug :match
  plug :dispatch

  @spec handle_request(map()) :: %{status: integer(), headers: [{binary(), binary()}], body: term()}
  def handle_request(%{method: method, path: path} = request)
      when is_binary(method) and is_binary(path) do
    result = execute_request(String.upcase(method), path, Map.get(request, :body))
    %{status: result.status, headers: @json_headers, body: result.body}
  end

  def handle_request(_request), do: %{status: 400, headers: @json_headers, body: %{error: "invalid request"}}

  get "/metrics" do
    result = execute_request("GET", "/metrics", nil)
    respond_json(conn, result.status, result.body)
  end

  get "/:key" do
    result = execute_request("GET", "/" <> key, nil)
    respond_json(conn, result.status, result.body)
  end

  post "/:key" do
    result = execute_request("POST", "/" <> key, conn.body_params)
    respond_json(conn, result.status, result.body)
  end

  delete "/:key" do
    result = execute_request("DELETE", "/" <> key, nil)
    respond_json(conn, result.status, result.body)
  end

  match _ do
    respond_json(conn, 404, %{error: "not found"})
  end

  defp parse_path("/metrics"), do: :metrics

  defp parse_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [key] -> {:ok, URI.decode(key)}
      _ -> :error
    end
  end

  defp execute_request(method, path, body) do
    case {method, parse_path(path)} do
      {"GET", :metrics} ->
        %{status: 200, body: MoyaDB.Metrics.snapshot()}

      {"GET", {:ok, key}} ->
        get_key(key)

      {"POST", {:ok, key}} ->
        value = unwrap_json_value(body)
        :ok = MoyaDB.put(key, value)
        %{status: 200, body: %{key: key, value: value}}

      {"DELETE", {:ok, key}} ->
        case MoyaDB.delete(key) do
          {:ok, _value} -> %{status: 200, body: %{key: key, deleted: true}}
          :error -> %{status: 404, body: %{error: "key not found"}}
        end

      {_method, :error} ->
        %{status: 404, body: %{error: "not found"}}

      {other_method, {:ok, _key}} ->
        %{status: 405, body: %{error: "method not allowed", method: other_method}}
    end
  end

  defp get_key(key) do
    case MoyaDB.get(key) do
      {:ok, value} ->
        body = %{key: key, value: value}

        case Jason.encode(body) do
          {:ok, _} -> %{status: 200, body: body}
          {:error, _} -> %{status: 422, body: %{error: "stored value is not JSON-serializable"}}
        end

      :error ->
        %{status: 404, body: %{error: "key not found"}}
    end
  end

  defp unwrap_json_value(%{"_json" => value}), do: value
  defp unwrap_json_value(value), do: value

  defp put_request_start(conn, _opts) do
    assign(conn, :request_start_native, System.monotonic_time())
  end

  defp respond_json(conn, status, body) do
    conn = put_resp_content_type(conn, "application/json")

    {status, payload} =
      case Jason.encode(body) do
        {:ok, json} -> {status, json}
        {:error, _} -> {422, Jason.encode!(%{error: "response is not JSON-serializable"})}
      end

    maybe_record_metrics(conn, status)
    send_resp(conn, status, payload)
  end

  defp maybe_record_metrics(conn, status) do
    if conn.request_path != "/db/v0.1/metrics" do
      start_native = conn.assigns[:request_start_native] || System.monotonic_time()
      latency_ms = System.convert_time_unit(System.monotonic_time() - start_native, :native, :microsecond) / 1000
      MoyaDB.Metrics.record(status, latency_ms)
    end

    :ok
  end
end
