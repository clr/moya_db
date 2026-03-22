defmodule MoyaDBTest do
  use ExUnit.Case, async: false
  doctest MoyaDB

  setup do
    MoyaDB.flush()
    :ok
  end

  describe "MoyaDB.Store via public API" do
    test "put and get a value" do
      assert :ok = MoyaDB.put("key", "value")
      assert {:ok, "value"} = MoyaDB.get("key")
    end

    test "get returns :error for missing key" do
      assert :error = MoyaDB.get("nonexistent")
    end

    test "delete removes a key" do
      MoyaDB.put("to_delete", 42)
      assert :ok = MoyaDB.delete("to_delete")
      assert :error = MoyaDB.get("to_delete")
    end

    test "delete is idempotent for missing keys" do
      assert :ok = MoyaDB.delete("never_existed")
    end

    test "all returns a map of all entries" do
      MoyaDB.put("a", 1)
      MoyaDB.put("b", 2)
      assert %{"a" => 1, "b" => 2} = MoyaDB.all()
    end

    test "flush clears all entries" do
      MoyaDB.put("x", "y")
      MoyaDB.flush()
      assert %{} = MoyaDB.all()
    end

    test "supports arbitrary term keys and values" do
      MoyaDB.put({:user, 1}, %{name: "Alice", age: 30})
      assert {:ok, %{name: "Alice"}} = MoyaDB.get({:user, 1})
    end

    test "overwriting a key replaces the value" do
      MoyaDB.put("counter", 1)
      MoyaDB.put("counter", 2)
      assert {:ok, 2} = MoyaDB.get("counter")
    end
  end

  describe "MoyaDB.node_info/0" do
    test "returns a map with expected keys" do
      info = MoyaDB.node_info()
      assert is_atom(info.node)
      assert is_list(info.connected_nodes)
      assert is_binary(info.otp_release)
      assert is_binary(info.elixir_version)
      assert is_pid(info.store_pid)
      assert is_integer(info.entries)
    end
  end
end
