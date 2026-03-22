defmodule MoyaDB do
  @moduledoc """
  MoyaDB — a distributed key-value database built on Elixir/OTP.

  This module exposes the top-level public API. Internally each node runs a
  supervised `MoyaDB.Store` GenServer. Replication, partitioning, and consensus
  will be layered on top of this foundation.

  ## Quick start

      iex -S mix
      iex> MoyaDB.put("hello", "world")
      :ok
      iex> MoyaDB.get("hello")
      {:ok, "world"}
      iex> MoyaDB.node_info()

  """

  alias MoyaDB.Store

  # --- Storage API ----------------------------------------------------------

  defdelegate put(key, value), to: Store
  defdelegate get(key), to: Store
  defdelegate delete(key), to: Store
  defdelegate all(), to: Store
  defdelegate flush(), to: Store

  # --- Node info ------------------------------------------------------------

  @doc """
  Returns a map describing the current node and application state.

      iex> info = MoyaDB.node_info()
      iex> is_atom(info.node)
      true

  """
  def node_info do
    %{
      node: Node.self(),
      connected_nodes: Node.list(),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      elixir_version: System.version(),
      store_pid: Process.whereis(Store),
      entries: map_size(Store.all())
    }
  end
end
