defmodule MoyaDB.Cluster do
  @moduledoc """
  Cluster bootstrap and membership management.

  On start it:
    1. Configures the Mnesia `:dir` for this node.
    2. Connects to any configured seed nodes via Erlang distribution.
    3. Stops and restarts Mnesia so our `:dir` is respected.
    4. For standalone nodes: creates the node-registry table.
       For joining nodes: joins the Mnesia cluster, then adds a local
       RAM replica of the registry table.
    5. Registers this node in the shared Mnesia registry.
    6. Subscribes to `:nodeup` / `:nodedown` events.

  On `:nodeup`  – refresh local registry row + run anti-entropy with the new peer.
  On `:nodedown` – remove that node from the registry.

  Configure seeds:

      config :moya_db, cluster_seeds: [:"b@myhost", :"c@myhost"]

  Use the same `--cookie` (or `~/.erlang.cookie`) on every node.
  """

  use GenServer

  require Logger

  @table_wait_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Returns `:pong` once handle_continue has finished.  Used in tests to block
  # until bootstrap is complete before sending any Mnesia or Store calls.
  def ping, do: GenServer.call(__MODULE__, :ping)

  @impl true
  def init(_opts) do
    seeds = Application.get_env(:moya_db, :cluster_seeds, [])
    {:ok, %{seeds: seeds}, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, %{seeds: seeds} = state) do
    :ok = connect_seeds(seeds)
    peers = live_peers(seeds)

    case do_bootstrap(peers) do
      :ok ->
        :ok = :net_kernel.monitor_nodes(true)
        Logger.info("MoyaDB.Cluster ready on #{node()}, Mnesia peers=#{inspect(peers)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("MoyaDB.Cluster bootstrap failed: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}

  @impl true
  def handle_info({:nodeup, remote}, state) do
    Logger.info("MoyaDB: nodeup #{inspect(remote)}")
    _ = MoyaDB.NodeRegistry.register()
    :ok = anti_entropy(remote)
    {:noreply, state}
  end

  def handle_info({:nodedown, remote}, state) do
    Logger.info("MoyaDB: nodedown #{inspect(remote)}")
    _ = MoyaDB.NodeRegistry.deregister(remote)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MoyaDB.Cluster unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Bootstrap helpers
  # ---------------------------------------------------------------------------

  defp do_bootstrap(peers) do
    with :ok <- configure_mnesia_directory(),
         :ok <- maybe_join_or_standalone(peers),
         :ok <- ensure_registry_table(peers),
         :ok <- MoyaDB.NodeRegistry.register() do
      :ok
    end
  end

  defp configure_mnesia_directory do
    dir = mnesia_directory()

    case File.mkdir_p(dir) do
      :ok ->
        Application.put_env(:mnesia, :dir, String.to_charlist(Path.expand(dir)))
        :ok

      {:error, reason} ->
        {:error, {:mkdir, reason}}
    end
  end

  defp mnesia_directory do
    root =
      Application.get_env(:moya_db, :mnesia_root) ||
        Application.app_dir(:moya_db, "priv/mnesia")

    Path.join(root, to_string(node()))
  end

  defp connect_seeds(seeds) do
    for s <- seeds, s != node() do
      result = Node.connect(s)

      if result != true do
        Logger.warning("MoyaDB: Node.connect(#{inspect(s)}) => #{inspect(result)}")
      end
    end

    :ok
  end

  defp live_peers(seeds) do
    seeds
    |> Enum.uniq()
    |> Enum.reject(&(&1 == node()))
    |> Enum.filter(&(Node.ping(&1) == :pong))
  end

  # Standalone: stop → start (fresh RAM schema), create table.
  defp maybe_join_or_standalone([]) do
    with :ok <- ensure_mnesia_stopped(),
         :ok <- start_mnesia() do
      :ok
    end
  end

  # Joining peers: stop → start → change_config to join the Mnesia cluster.
  defp maybe_join_or_standalone(peers) do
    with :ok <- ensure_mnesia_stopped(),
         :ok <- start_mnesia(),
         :ok <- join_mnesia_peers(peers) do
      :ok
    end
  end

  defp join_mnesia_peers(peers) do
    case :mnesia.change_config(:extra_db_nodes, peers) do
      {:ok, _connected} -> :ok
      {:error, reason} -> {:error, {:mnesia_join, reason}}
    end
  end

  defp ensure_registry_table([]) do
    create_registry_table()
  end

  defp ensure_registry_table(_peers) do
    t = MoyaDB.NodeRegistry.table()

    with :ok <- add_local_copy(t) do
      case :mnesia.wait_for_tables([t], @table_wait_timeout) do
        :ok -> :ok
        {:timeout, bad} -> {:error, {:wait_for_tables, bad}}
      end
    end
  end

  defp create_registry_table do
    t = MoyaDB.NodeRegistry.table()

    case :mnesia.create_table(t,
           attributes: [:node, :hostname, :registered_at],
           type: :set,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^t}} -> :ok
      {:aborted, reason} -> {:error, {:create_table, reason}}
    end
  end

  defp add_local_copy(t) do
    case :mnesia.add_table_copy(t, node(), :ram_copies) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^t, _node}} -> :ok
      {:aborted, reason} -> {:error, {:add_table_copy, reason}}
    end
  end

  defp ensure_mnesia_stopped do
    case Application.stop(:mnesia) do
      :ok -> :ok
      {:error, {:not_started, :mnesia}} -> :ok
      {:error, reason} -> {:error, {:mnesia_stop, reason}}
    end
  end

  defp start_mnesia do
    case Application.ensure_started(:mnesia) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mnesia_start, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Anti-entropy
  # ---------------------------------------------------------------------------

  # Push our entire Store state to the new peer so it fills any gaps, and pull
  # its state so we fill ours.  Local values win on key conflict in both
  # directions.  NOTE: without per-key timestamps this cannot resolve deletes
  # that happened while a node was partitioned; LWW is the natural next step.
  defp anti_entropy(remote) do
    local = MoyaDB.Store.all()
    GenServer.cast({MoyaDB.Store, remote}, {:merge, local})

    case :rpc.call(remote, MoyaDB.Store, :all, []) do
      {:badrpc, _} -> :ok
      remote_state -> MoyaDB.Store.merge(remote_state)
    end

    :ok
  end
end
