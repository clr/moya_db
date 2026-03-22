defmodule MoyaDB.NodeRegistry do
  @moduledoc """
  Mnesia-backed registry of cluster members.

  Each row is `{:moya_db_node_registry, node, hostname, registered_at}`.
  The table is `ram_copies` on every node — it is rebuilt from live
  registrations on each boot, so it always reflects the current cluster.

  All operations use `Node.self()` for the local node; remote nodes register
  themselves when they boot.  `deregister/1` accepts an explicit node name so
  callers can remove a peer that has gone down.
  """

  @table :moya_db_node_registry

  @doc false
  def table, do: @table

  @doc """
  Inserts or updates a registration row for `Node.self()`.
  The hostname is always resolved locally.
  """
  def register do
    hostname =
      case :inet.gethostname() do
        {:ok, h} -> List.to_string(h)
        _ -> ""
      end

    rec = {@table, Node.self(), hostname, System.system_time(:second)}

    case :mnesia.transaction(fn -> :mnesia.write(rec) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Removes the registry entry for `node`."
  def deregister(node) do
    case :mnesia.transaction(fn -> :mnesia.delete({@table, node}) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all registry rows as a list of maps with keys
  `:node`, `:hostname`, `:registered_at`.
  """
  def list do
    case :mnesia.transaction(fn ->
           :mnesia.foldl(fn row, acc -> [row_to_map(row) | acc] end, [], @table)
         end) do
      {:atomic, rows} -> rows
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp row_to_map({@table, node, hostname, registered_at}) do
    %{node: node, hostname: hostname, registered_at: registered_at}
  end
end
