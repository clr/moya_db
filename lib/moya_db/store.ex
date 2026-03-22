defmodule MoyaDB.Store do
  @moduledoc """
  In-memory key-value store backed by a GenServer.

  This is the foundational storage layer for MoyaDB. Each node in a distributed
  cluster will run its own Store process; replication and partitioning will be
  layered on top.
  """

  use GenServer

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Store a value under `key`. Returns `:ok`."
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc "Retrieve the value for `key`. Returns `{:ok, value}` or `:error`."
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @doc "Delete the entry for `key`. Returns `:ok`."
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @doc "Return all key-value pairs as a map."
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Remove every entry. Returns `:ok`."
  def flush, do: GenServer.call(__MODULE__, :flush)

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(initial_state), do: {:ok, initial_state}

  @impl true
  def handle_call({:put, key, value}, _from, state),
    do: {:reply, :ok, Map.put(state, key, value)}

  def handle_call({:get, key}, _from, state),
    do: {:reply, Map.fetch(state, key), state}

  def handle_call({:delete, key}, _from, state),
    do: {:reply, :ok, Map.delete(state, key)}

  def handle_call(:all, _from, state),
    do: {:reply, state, state}

  def handle_call(:flush, _from, _state),
    do: {:reply, :ok, %{}}
end
