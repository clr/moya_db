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

  describe "POST /v0.1/db/:key" do
    test "stores a JSON object and returns 200 with key and value" do
      conn = api(:post, "/v0.1/db/user1", %{"name" => "Alice", "age" => 30})

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "user1"
      assert body["value"]["name"] == "Alice"
      assert body["value"]["age"] == 30
    end

    test "stores a JSON string value" do
      conn = api(:post, "/v0.1/db/greeting", "hello")

      assert conn.status == 200
      assert json(conn)["value"] == "hello"
    end

    test "stores a JSON array value" do
      conn = api(:post, "/v0.1/db/tags", ["elixir", "otp", "distributed"])

      assert conn.status == 200
      assert json(conn)["value"] == ["elixir", "otp", "distributed"]
    end

    test "stores a JSON number value" do
      conn = api(:post, "/v0.1/db/count", 42)

      assert conn.status == 200
      assert json(conn)["value"] == 42
    end

    test "is idempotent — re-posting the same key replaces the value" do
      api(:post, "/v0.1/db/item", %{"v" => 1})
      conn = api(:post, "/v0.1/db/item", %{"v" => 2})

      assert conn.status == 200
      assert json(conn)["value"]["v"] == 2
    end

    test "response Content-Type is application/json" do
      conn = api(:post, "/v0.1/db/ct_test", %{"x" => 1})
      [ct | _] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # ---------------------------------------------------------------------------
  # GET — read a value back
  # ---------------------------------------------------------------------------

  describe "GET /v0.1/db/:key" do
    test "returns 200 and the stored value after a POST" do
      api(:post, "/v0.1/db/profile", %{"role" => "admin"})
      conn = api(:get, "/v0.1/db/profile")

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "profile"
      assert body["value"]["role"] == "admin"
    end

    test "returns 200 for a value stored directly via the Store API" do
      MoyaDB.put("direct", %{"source" => "store"})
      conn = api(:get, "/v0.1/db/direct")

      assert conn.status == 200
      assert json(conn)["value"]["source"] == "store"
    end

    test "returns 404 for a key that does not exist" do
      conn = api(:get, "/v0.1/db/nonexistent")

      assert conn.status == 404
      assert json(conn)["error"] == "key not found"
    end

    test "returns 404 after the key has been deleted" do
      api(:post, "/v0.1/db/ephemeral", %{"x" => 1})
      api(:delete, "/v0.1/db/ephemeral")
      conn = api(:get, "/v0.1/db/ephemeral")

      assert conn.status == 404
    end

    test "response Content-Type is application/json" do
      MoyaDB.put("ct", 1)
      conn = api(:get, "/v0.1/db/ct")
      [ct | _] = get_resp_header(conn, "content-type")
      assert ct =~ "application/json"
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE — remove a key-value pair
  # ---------------------------------------------------------------------------

  describe "DELETE /v0.1/db/:key" do
    test "returns 200 with deleted:true when the key exists" do
      api(:post, "/v0.1/db/to_delete", %{"bye" => true})
      conn = api(:delete, "/v0.1/db/to_delete")

      assert conn.status == 200
      body = json(conn)
      assert body["key"] == "to_delete"
      assert body["deleted"] == true
    end

    test "removes the key so a subsequent GET returns 404" do
      api(:post, "/v0.1/db/gone", %{"x" => 1})
      api(:delete, "/v0.1/db/gone")

      assert api(:get, "/v0.1/db/gone").status == 404
    end

    test "returns 404 when the key does not exist" do
      conn = api(:delete, "/v0.1/db/ghost")

      assert conn.status == 404
      assert json(conn)["error"] == "key not found"
    end

    test "response Content-Type is application/json" do
      MoyaDB.put("del_ct", 1)
      conn = api(:delete, "/v0.1/db/del_ct")
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
      post_conn = api(:post, "/v0.1/db/#{key}", value)
      assert post_conn.status == 200

      # Read back
      get_conn = api(:get, "/v0.1/db/#{key}")
      assert get_conn.status == 200
      assert json(get_conn)["value"] == value

      # Delete
      del_conn = api(:delete, "/v0.1/db/#{key}")
      assert del_conn.status == 200
      assert json(del_conn)["deleted"] == true

      # Confirm gone
      assert api(:get, "/v0.1/db/#{key}").status == 404
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
      conn = api(:get, "/v0.1/something/else")

      assert conn.status == 404
    end
  end
end