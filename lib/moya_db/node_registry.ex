defmodule MoyaDB.NodeRegistry do
  @moduledoc """
  Mnesia-backed registry of cluster members.

  Each row is `{:moya_db_node_registry, node, hostname, registered_at}`.
  The first attribute is the Mnesia key (`:set` table).
  """

  @table :moya_db_node_registry

  @doc false
  def table, do: @table

  @doc """
  Inserts or updates this node's registration (typically called on boot after
  the table is available on this node).
  """
  def register(node \\ Node.self()) do
    hostname =
      case :inet.gethostname() do
        {:ok, h} -> List.to_string(h)
        _ -> ""
      end

    rec = {@table, node, hostname, System.system_time(:second)}

    case :mnesia.transaction(fn -> :mnesia.write(rec) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all registry rows as maps with keys `:node`, `:hostname`, `:registered_at`.
  """
  def list do
    case :mnesia.transaction(fn ->
           :mnesia.foldl(fn r, acc -> [normalize_row(r) | acc] end, [], @table)
         end) do
      {:atomic, rows} -> rows
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp normalize_row({@table, node, hostname, registered_at}) do
    %{node: node, hostname: hostname, registered_at: registered_at}
  end
end
