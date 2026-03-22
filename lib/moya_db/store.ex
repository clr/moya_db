defmodule MoyaDB.Store do
  @moduledoc """
  In-memory key-value store backed by a GenServer.

  This is the foundational storage layer for MoyaDB. Each node runs its own
  Store process.  Write operations (`put`, `delete`, `flush`) are applied
  locally first, then broadcast asynchronously to every connected peer via
  replica casts so the call returns at local-write latency.

  Peers receive `{:replicate_put, k, v}`, `{:replicate_delete, k}`, and
  `:replicate_flush` casts that update state without re-broadcasting,
  preventing replication loops.

  Anti-entropy on reconnect is handled by `merge/1`, which merges a remote
  snapshot into local state with **local-wins** semantics on key conflict.
  """

  use GenServer

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Store a value under `key`. Replicates to peers. Returns `:ok`."
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc "Retrieve the value for `key`. Returns `{:ok, value}` or `:error`."
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc "Delete the entry for `key`. Replicates to peers. Returns `:ok`."
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @doc "Return all key-value pairs as a map."
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Remove every entry. Replicates to peers. Returns `:ok`."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc """
  Merge `remote_map` into local state.  Local values win on key conflict;
  keys present only in `remote_map` are added.  Fire-and-forget (cast).
  """
  def merge(remote_map), do: GenServer.cast(__MODULE__, {:merge, remote_map})

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(initial_state), do: {:ok, initial_state}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    broadcast({:replicate_put, key, value})
    {:reply, :ok, Map.put(state, key, value)}
  end

  def handle_call({:get, key}, _from, state),
    do: {:reply, Map.fetch(state, key), state}

  def handle_call({:delete, key}, _from, state) do
    broadcast({:replicate_delete, key})
    {:reply, :ok, Map.delete(state, key)}
  end

  def handle_call(:all, _from, state),
    do: {:reply, state, state}

  def handle_call(:flush, _from, _state) do
    broadcast(:replicate_flush)
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_cast({:replicate_put, key, value}, state),
    do: {:noreply, Map.put(state, key, value)}

  def handle_cast({:replicate_delete, key}, state),
    do: {:noreply, Map.delete(state, key)}

  def handle_cast(:replicate_flush, _state),
    do: {:noreply, %{}}

  def handle_cast({:merge, remote_map}, state),
    do: {:noreply, Map.merge(remote_map, state)}

  # --- Private helpers ------------------------------------------------------

  defp broadcast(msg) do
    for n <- Node.list(), do: GenServer.cast({__MODULE__, n}, msg)
    :ok
  end
end
