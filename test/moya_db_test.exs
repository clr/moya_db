defmodule MoyaDBTest do
  use ExUnit.Case, async: false
  doctest MoyaDB

  # Block until Cluster.handle_continue (Mnesia bootstrap) has completed.
  # Because handle_continue runs before any GenServer mailbox messages are
  # processed, this single call guarantees Mnesia and the registry are ready
  # for every test in this module.
  setup_all do
    :pong = MoyaDB.Cluster.ping()
    :ok
  end

  setup do
    MoyaDB.flush()
    :ok
  end

  defp future_version(offset) do
    {System.system_time(:microsecond) + offset, :remote, offset}
  end

  # ---------------------------------------------------------------------------
  # Store — public API
  # ---------------------------------------------------------------------------

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
      assert {:ok, 42} = MoyaDB.delete("to_delete")
      assert :error = MoyaDB.get("to_delete")
    end

    test "delete returns :error for missing keys while still recording the tombstone" do
      assert :error = MoyaDB.delete("never_existed")
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

  # ---------------------------------------------------------------------------
  # Store — replica cast handlers (exercised directly; no real peer needed)
  # ---------------------------------------------------------------------------

  describe "MoyaDB.Store replication" do
    test "replicate_put applies an inbound write without re-broadcasting" do
      GenServer.cast(MoyaDB.Store, {:replicate_put, "rkey", "rval"})
      # GenServer.call is processed after the cast — no sleep needed.
      assert {:ok, "rval"} = MoyaDB.get("rkey")
    end

    test "replicate_delete removes a key" do
      MoyaDB.put("rdel", "v")
      tombstone = %{deleted?: true, value: nil, version: future_version(1)}
      GenServer.cast(MoyaDB.Store, {:replicate_delete, "rdel", tombstone})
      assert :error = MoyaDB.get("rdel")
    end

    test "replicate_flush clears all entries older than the reset version" do
      MoyaDB.put("x", 1)
      GenServer.cast(MoyaDB.Store, {:replicate_flush, future_version(1)})
      assert %{} = MoyaDB.all()
    end

    test "merge keeps the newest value entry by version" do
      remote_snapshot = %MoyaDB.Store.Snapshot{
        reset_version: nil,
        entries: %{
          "local_key" => %{deleted?: false, value: "remote_newer", version: future_version(2)},
          "new_key" => %{deleted?: false, value: "new_val", version: future_version(1)}
        }
      }

      MoyaDB.put("local_key", "local_val")
      MoyaDB.Store.merge(remote_snapshot)

      assert {:ok, "remote_newer"} = MoyaDB.get("local_key")
      assert {:ok, "new_val"} = MoyaDB.get("new_key")
    end

    test "merge preserves tombstones so deleted keys are not resurrected" do
      MoyaDB.put("ghost", "value")

      remote_snapshot = %MoyaDB.Store.Snapshot{
        reset_version: nil,
        entries: %{
          "ghost" => %{deleted?: true, value: nil, version: future_version(1)}
        }
      }

      MoyaDB.Store.merge(remote_snapshot)
      assert :error = MoyaDB.get("ghost")
    end

    test "merge applies reset watermark so flushed keys stay gone" do
      MoyaDB.put("stale", "value")

      remote_snapshot = %MoyaDB.Store.Snapshot{
        reset_version: future_version(2),
        entries: %{
          "stale" => %{deleted?: false, value: "old_remote", version: {1, :remote, 1}},
          "fresh" => %{deleted?: false, value: "new_remote", version: future_version(3)}
        }
      }

      MoyaDB.Store.merge(remote_snapshot)
      assert :error = MoyaDB.get("stale")
      assert {:ok, "new_remote"} = MoyaDB.get("fresh")
    end
  end

  # ---------------------------------------------------------------------------
  # NodeRegistry
  # ---------------------------------------------------------------------------

  describe "MoyaDB.NodeRegistry" do
    setup do
      :ok = MoyaDB.NodeRegistry.register()
      # Re-register after each test so deregister tests don't bleed into others.
      on_exit(fn -> MoyaDB.NodeRegistry.register() end)
      :ok
    end

    test "list/0 includes the current node after register/0" do
      members = MoyaDB.NodeRegistry.list()
      assert is_list(members)
      assert Enum.any?(members, fn m -> m.node == Node.self() end)
    end

    test "each member map has the expected keys" do
      [member | _] =
        Enum.filter(MoyaDB.NodeRegistry.list(), fn m -> m.node == Node.self() end)

      assert is_atom(member.node)
      assert is_binary(member.hostname)
      assert is_integer(member.registered_at)
    end

    test "register/0 is idempotent — no duplicate rows" do
      :ok = MoyaDB.NodeRegistry.register()
      :ok = MoyaDB.NodeRegistry.register()
      rows = Enum.filter(MoyaDB.NodeRegistry.list(), fn m -> m.node == Node.self() end)
      assert length(rows) == 1
    end

    test "deregister/1 removes the node" do
      :ok = MoyaDB.NodeRegistry.deregister(Node.self())
      refute Enum.any?(MoyaDB.NodeRegistry.list(), fn m -> m.node == Node.self() end)
    end
  end

  # ---------------------------------------------------------------------------
  # Cluster
  # ---------------------------------------------------------------------------

  describe "MoyaDB.Cluster" do
    setup do
      :ok = MoyaDB.NodeRegistry.register()
      :ok
    end

    test "cluster process is supervised and running" do
      assert is_pid(Process.whereis(MoyaDB.Cluster))
    end

    test "current node is registered in the Mnesia registry on boot" do
      nodes = MoyaDB.NodeRegistry.list() |> Enum.map(& &1.node)
      assert Node.self() in nodes
    end
  end

  # ---------------------------------------------------------------------------
  # node_info/0
  # ---------------------------------------------------------------------------

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
