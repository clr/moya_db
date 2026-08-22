defmodule MoyaDB.APITest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  # Initialise the router once; the options are immutable.
  @opts MoyaDB.API.init([])

  # Ensure Mnesia/Cluster bootstrap is complete before any test runs.
  setup_all do
    :pong = MoyaDB.Cluster.ping()
    :ok
  end

  setup do
    MoyaDB.flush()
    MoyaDB.Metrics.reset()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp api(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    MoyaDB.API.call(conn, @opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ---------------------------------------------------------------------------
  # POST — store a value
  # ---------------------------------------------------------------------------

  describe "POST /db/v0.1/:key" do
    test "stores a JSON object and returns 200 with key and value" do
      conn = api(:post, "/db/v0.1/user1", %{"name" => "Alice", "age" => 30})

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "user1"
      assert body["value"]["name"] == "Alice"
      assert body["value"]["age"] == 30
    end

    test "stores a JSON string value" do
      conn = api(:post, "/db/v0.1/greeting", "hello")

      assert conn.status == 200
      assert json(conn)["value"] == "hello"
    end

    test "stores a JSON array value" do
      conn = api(:post, "/db/v0.1/tags", ["elixir", "otp", "distributed"])

      assert conn.status == 200
      assert json(conn)["value"] == ["elixir", "otp", "distributed"]
    end

    test "stores a JSON number value" do
      conn = api(:post, "/db/v0.1/count", 42)

      assert conn.status == 200
      assert json(conn)["value"] == 42
    end

    test "is idempotent — re-posting the same key replaces the value" do
      api(:post, "/db/v0.1/item", %{"v" => 1})
      conn = api(:post, "/db/v0.1/item", %{"v" => 2})

      assert conn.status == 200
      assert json(conn)["value"]["v"] == 2
    end

    test "response Content-Type is application/json" do
      conn = api(:post, "/db/v0.1/ct_test", %{"x" => 1})
      [ct | _] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # ---------------------------------------------------------------------------
  # GET — read a value back
  # ---------------------------------------------------------------------------

  describe "GET /db/v0.1/:key" do
    test "returns 200 and the stored value after a POST" do
      api(:post, "/db/v0.1/profile", %{"role" => "admin"})
      conn = api(:get, "/db/v0.1/profile")

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "profile"
      assert body["value"]["role"] == "admin"
    end

    test "returns 200 for a value stored directly via the Store API" do
      MoyaDB.put("direct", %{"source" => "store"})
      conn = api(:get, "/db/v0.1/direct")

      assert conn.status == 200
      assert json(conn)["value"]["source"] == "store"
    end

    test "returns 404 for a key that does not exist" do
      conn = api(:get, "/db/v0.1/nonexistent")

      assert conn.status == 404
      assert json(conn)["error"] == "key not found"
    end

    test "returns 404 after the key has been deleted" do
      api(:post, "/db/v0.1/ephemeral", %{"x" => 1})
      api(:delete, "/db/v0.1/ephemeral")
      conn = api(:get, "/db/v0.1/ephemeral")

      assert conn.status == 404
    end

    test "response Content-Type is application/json" do
      MoyaDB.put("ct", 1)
      conn = api(:get, "/db/v0.1/ct")
      [ct | _] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE — remove a key-value pair
  # ---------------------------------------------------------------------------

  describe "DELETE /db/v0.1/:key" do
    test "returns 200 with deleted:true when the key exists" do
      api(:post, "/db/v0.1/to_delete", %{"bye" => true})
      conn = api(:delete, "/db/v0.1/to_delete")

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "to_delete"
      assert body["deleted"] == true
    end

    test "removes the key so a subsequent GET returns 404" do
      api(:post, "/db/v0.1/gone", %{"x" => 1})
      api(:delete, "/db/v0.1/gone")

      assert api(:get, "/db/v0.1/gone").status == 404
    end

    test "returns 404 when the key does not exist" do
      conn = api(:delete, "/db/v0.1/ghost")

      assert conn.status == 404
      assert json(conn)["error"] == "key not found"
    end

    test "response Content-Type is application/json" do
      MoyaDB.put("del_ct", 1)
      conn = api(:delete, "/db/v0.1/del_ct")
      [ct | _] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # ---------------------------------------------------------------------------
  # Full round-trip
  # ---------------------------------------------------------------------------

  describe "round-trip" do
    test "POST → GET → DELETE → GET" do
      key = "roundtrip"
      value = %{"status" => "ok", "count" => 7}

      # Store
      post_conn = api(:post, "/db/v0.1/#{key}", value)
      assert post_conn.status == 200

      # Read back
      get_conn = api(:get, "/db/v0.1/#{key}")
      assert get_conn.status == 200
      assert json(get_conn)["value"] == value

      # Delete
      del_conn = api(:delete, "/db/v0.1/#{key}")
      assert del_conn.status == 200
      assert json(del_conn)["deleted"] == true

      # Confirm gone
      assert api(:get, "/db/v0.1/#{key}").status == 404
    end
  end

  # ---------------------------------------------------------------------------
  # Routing / catch-all
  # ---------------------------------------------------------------------------

  describe "unknown routes" do
    test "returns 404 for an unrecognised path" do
      conn = api(:get, "/does/not/exist")

      assert conn.status == 404
    end

    test "returns 404 for an unrecognised versioned path" do
      conn = api(:get, "/db/v0.1/something/else")

      assert conn.status == 404
    end
  end

  describe "GET /db/v0.1/metrics" do
    test "returns rolling inbound counts and health latency percentiles" do
      api(:post, "/db/v0.1/m1", %{"v" => 1})
      api(:get, "/db/v0.1/m1")
      api(:delete, "/db/v0.1/m1")
      api(:get, "/db/v0.1/missing")

      conn = api(:get, "/db/v0.1/metrics")

      assert conn.status == 200
      body = json(conn)

      assert body["window_ms"] == 1_000
      assert is_integer(body["timestamp"])
      assert body["role"] == "database"
      assert body["db_id"] == "db-1"

      inbound = body["inbound"]
      assert inbound["query_count"] == 4
      assert inbound["responses"]["2xx"] == 3
      assert inbound["responses"]["4xx"] == 1
      assert inbound["responses"]["5xx"] == 0
      assert inbound["last_status"] == 404

      health = body["health"]
      assert health["ready"] == true
      assert is_number(health["latency_ms_p50"])
      assert is_number(health["latency_ms_p95"])
      assert health["latency_ms_p50"] <= health["latency_ms_p95"]
    end

    test "does not count the metrics endpoint itself as inbound traffic" do
      api(:post, "/db/v0.1/only_once", %{"v" => true})

      first = api(:get, "/db/v0.1/metrics") |> json()
      second = api(:get, "/db/v0.1/metrics") |> json()

      assert first["inbound"]["query_count"] == 1
      assert second["inbound"]["query_count"] == 1
    end
  end

  describe "handle_request/1 parity" do
    test "returns the same 422 body for non-JSON-serializable stored values" do
      MoyaDB.put("opaque", %{value: self()})

      conn = api(:get, "/db/v0.1/opaque")

      response =
        MoyaDB.API.handle_request(%{
          method: "GET",
          path: "/db/v0.1/opaque"
        })

      assert conn.status == 422
      assert json(conn)["error"] == "stored value is not JSON-serializable"
      assert response.status == 422
      assert response.body == %{error: "stored value is not JSON-serializable"}
    end

    test "uses single-step delete semantics consistently" do
      api(:post, "/db/v0.1/delete_me_conn", %{"v" => 1})
      api(:post, "/db/v0.1/delete_me_handle", %{"v" => 1})

      conn = api(:delete, "/db/v0.1/delete_me_conn")

      response =
        MoyaDB.API.handle_request(%{
          method: "DELETE",
          path: "/db/v0.1/delete_me_handle"
        })

      assert conn.status == 200
      assert json(conn) == %{"deleted" => true, "key" => "delete_me_conn"}
      assert response.status == 200
      assert response.body == %{key: "delete_me_handle", deleted: true}
    end
  end
end
