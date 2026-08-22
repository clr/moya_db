defmodule MoyaDB.Store do
  @moduledoc """
  In-memory key-value store backed by ETS.

  This is the foundational storage layer for MoyaDB. Each node keeps its hot
  key/value data in ETS so reads avoid a single process mailbox. A lightweight
  Store process remains in place to serialize replication and merge operations.

  Write operations (`put`, `delete`, `flush`) are still applied locally first,
  then broadcast asynchronously to every connected peer via replica casts so
  the call returns at local-write latency.

  Each key is stored with a version and tombstone metadata so reconnect merge
  can preserve deletes instead of resurrecting stale values. A flush advances a
  reset watermark; entries older than that watermark are ignored on merge.
  """

  use GenServer

  defmodule Snapshot do
    @enforce_keys [:entries, :reset_version]
    defstruct [:entries, :reset_version]
  end

  @entries_table __MODULE__.Entries
  @meta_table __MODULE__.Meta

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Store a value under `key`. Replicates to peers. Returns `:ok`."
  def put(key, value) do
    version = next_version()
    entry = value_entry(value, version)
    GenServer.cast(__MODULE__, {:broadcast, {:replicate_put, key, entry}})
    put_entry(key, entry)
    :ok
  end

  @doc "Retrieve the value for `key`. Returns `{:ok, value}` or `:error`."
  def get(key), do: fetch_visible(key)

  @doc "Delete the entry for `key`. Replicates tombstones. Returns `{:ok, value}` or `:error`."
  def delete(key) do
    version = next_version()
    tombstone = tombstone_entry(version)
    result = fetch_visible(key)
    GenServer.cast(__MODULE__, {:broadcast, {:replicate_delete, key, tombstone}})
    put_entry(key, tombstone)
    result
  end

  @doc "Return all key-value pairs as a map."
  def all, do: visible_entries()

  @doc "Remove every entry. Replicates to peers. Returns `:ok`."
  def flush do
    reset_version = next_version()
    GenServer.cast(__MODULE__, {:broadcast, {:replicate_flush, reset_version}})
    apply_reset(reset_version)
    :ok
  end

  @doc "Return the full replication snapshot, including tombstones and reset watermark."
  def snapshot do
    %Snapshot{entries: all_entries(), reset_version: current_reset_version()}
  end

  @doc "Merge a remote replication snapshot into local state. Fire-and-forget (cast)."
  def merge(snapshot), do: GenServer.cast(__MODULE__, {:merge, normalize_snapshot(snapshot)})

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(:ok) do
    ensure_tables!()
    clear_entries()
    put_reset_version(nil)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:broadcast, msg}, state) do
    broadcast(msg)
    {:noreply, state}
  end

  def handle_cast({:replicate_put, key, entry}, state) do
    put_entry(key, normalize_entry(entry))
    {:noreply, state}
  end

  def handle_cast({:replicate_delete, key, tombstone}, state) do
    put_entry(key, normalize_entry(tombstone))
    {:noreply, state}
  end

  def handle_cast({:replicate_delete, key}, state) do
    put_entry(key, tombstone_entry(next_version()))
    {:noreply, state}
  end

  def handle_cast({:replicate_flush, reset_version}, state) do
    apply_reset(reset_version)
    {:noreply, state}
  end

  def handle_cast(:replicate_flush, state) do
    apply_reset(next_version())
    {:noreply, state}
  end

  def handle_cast({:merge, remote_snapshot}, state) do
    merge_snapshots(snapshot(), remote_snapshot)
    {:noreply, state}
  end

  # --- Private helpers ------------------------------------------------------

  defp broadcast(msg) do
    for n <- Node.list(), do: GenServer.cast({__MODULE__, n}, msg)
    :ok
  end

  defp visible_entries do
    all_entries()
    |> Enum.reduce(%{}, fn
      {key, %{deleted?: false, value: value}}, acc -> Map.put(acc, key, value)
      {_key, _entry}, acc -> acc
    end)
  end

  defp fetch_visible(key) do
    case lookup_entry(key) do
      %{deleted?: false, value: value} -> {:ok, value}
      _ -> :error
    end
  end

  defp value_entry(value, version), do: %{deleted?: false, value: value, version: version}
  defp tombstone_entry(version), do: %{deleted?: true, value: nil, version: version}

  defp put_entry(key, entry) do
    entry = normalize_entry(entry)
    reset_version = current_reset_version()

    if entry_newer_than_reset?(entry, reset_version) do
      current = lookup_entry(key)

      if newer_entry?(entry, current) do
        :ets.insert(@entries_table, {key, entry})
      end
    end

    :ok
  end

  defp apply_reset(reset_version) do
    merged_reset = max_version(current_reset_version(), reset_version)

    for {key, entry} <- all_entries() do
      if not entry_newer_than_reset?(entry, merged_reset) do
        :ets.delete(@entries_table, key)
      end
    end

    put_reset_version(merged_reset)
    :ok
  end

  defp merge_snapshots(%Snapshot{} = local, %Snapshot{} = remote) do
    merged_reset = max_version(local.reset_version, remote.reset_version)

    local_entries = drop_entries_before_reset(local.entries, merged_reset)
    remote_entries = drop_entries_before_reset(remote.entries, merged_reset)

    merged_entries =
      Map.merge(local_entries, remote_entries, fn _key, left, right ->
        if newer_entry?(left, right), do: left, else: right
      end)

    clear_entries()

    Enum.each(merged_entries, fn {key, entry} ->
      :ets.insert(@entries_table, {key, entry})
    end)

    put_reset_version(merged_reset)
    :ok
  end

  defp drop_entries_before_reset(entries, reset_version) do
    Enum.reduce(entries, %{}, fn {key, entry}, acc ->
      if entry_newer_than_reset?(entry, reset_version) do
        Map.put(acc, key, entry)
      else
        acc
      end
    end)
  end

  defp newer_entry?(_entry, nil), do: true
  defp newer_entry?(%{version: left}, %{version: right}), do: compare_versions(left, right) == :gt

  defp entry_newer_than_reset?(_entry, nil), do: true
  defp entry_newer_than_reset?(%{version: version}, reset_version), do: compare_versions(version, reset_version) == :gt

  defp max_version(nil, version), do: version
  defp max_version(version, nil), do: version

  defp max_version(left, right) do
    case compare_versions(left, right) do
      :lt -> right
      _ -> left
    end
  end

  defp compare_versions(left, right) do
    cond do
      left > right -> :gt
      left < right -> :lt
      true -> :eq
    end
  end

  defp next_version do
    {System.system_time(:microsecond), node(), System.unique_integer([:positive, :monotonic])}
  end

  defp normalize_snapshot(%Snapshot{} = snapshot), do: snapshot

  defp normalize_snapshot(%{entries: entries, reset_version: reset_version}) do
    %Snapshot{
      entries: Enum.into(entries, %{}, fn {key, entry} -> {key, normalize_entry(entry)} end),
      reset_version: reset_version
    }
  end

  defp normalize_entry(%{deleted?: deleted?, value: value, version: version}) do
    %{deleted?: deleted?, value: value, version: version}
  end

  defp normalize_entry(value) do
    value_entry(value, next_version())
  end

  defp ensure_tables! do
    case :ets.whereis(@entries_table) do
      :undefined ->
        :ets.new(@entries_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _tid ->
        :ok
    end

    case :ets.whereis(@meta_table) do
      :undefined ->
        :ets.new(@meta_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _tid ->
        :ok
    end
  end

  defp clear_entries do
    :ets.delete_all_objects(@entries_table)
  end

  defp lookup_entry(key) do
    case :ets.lookup(@entries_table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  end

  defp all_entries do
    @entries_table
    |> :ets.tab2list()
    |> Enum.into(%{}, fn {key, entry} -> {key, entry} end)
  end

  defp current_reset_version do
    case :ets.lookup(@meta_table, :reset_version) do
      [{:reset_version, version}] -> version
      [] -> nil
    end
  end

  defp put_reset_version(version) do
    :ets.insert(@meta_table, {:reset_version, version})
    :ok
  end
end
