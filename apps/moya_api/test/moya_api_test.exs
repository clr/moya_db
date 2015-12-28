defmodule MoyaApiTest do
  use ExUnit.Case, async: true

  test "returns something" do
    conn = Plug.Test.conn(:get, "/kv/b/v")
    conn = MoyaApi.call(conn, MoyaApi.init([]))

    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == "value"
  end
end
