defmodule MoyaDB.Cluster do
  @moduledoc """
  Cluster bootstrap: connects to configured seed nodes, joins or starts Mnesia,
  ensures the shared node registry table exists on this node, and registers
  the local node.

  Configure seeds with `config :moya_db, cluster_seeds: [:"a@host", ...]`.
  Use the same cookie on every node (`--cookie` or `~/.erlang.cookie`).
  """

  use GenServer

  require Logger

  @wait_timeout 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = configure_mnesia_directory()

    seeds = Application.get_env(:moya_db, :cluster_seeds, [])
    :ok = connect_seeds(seeds)

    peers = live_peers(seeds)

    with :ok <- maybe_join_or_standalone(peers),
         :ok <- ensure_registry_table_present(peers),
         :ok <- register_self() do
      :ok = :net_kernel.monitor_nodes(self(), true)
      Logger.info("MoyaDB cluster ready on #{node()}, registry peers=#{inspect(peers)}")
      {:ok, %{seeds: seeds}}
    else
      {:error, reason} = err ->
        Logger.error("MoyaDB cluster bootstrap failed: #{inspect(reason)}")
        {:stop, err}
    end
  end

  @impl true
  def handle_info({:nodeup, remote}, state) do
    Logger.debug("MoyaDB: nodeup #{inspect(remote)}")
    # Remote nodes register themselves when they boot; optionally refresh our row.
    _ = MoyaDB.NodeRegistry.register(Node.self())
    {:noreply, state}
  end

  def handle_info({:nodedown, remote}, state) do
    Logger.debug("MoyaDB: nodedown #{inspect(remote)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MoyaDB.Cluster unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp configure_mnesia_directory do
    dir = mnesia_directory()
    :ok = File.mkdir_p(dir)
    char = String.to_charlist(Path.expand(dir))
    :ok = :application.set_env(:mnesia, :dir, char)
  end

  defp mnesia_directory do
    case Application.get_env(:moya_db, :mnesia_root) do
      nil ->
        Application.app_dir(:moya_db, ["priv", "mnesia", to_string(node())])

      root ->
        Path.join([root, to_string(node())])
    end
  end

  defp connect_seeds(seeds) do
    for s <- seeds, s != node() do
      case Node.connect(s) do
        true -> :ok
        false -> Logger.warning("MoyaDB: Node.connect(#{inspect(s)}) returned false")
        :ignored -> Logger.warning("MoyaDB: not distributed; Node.connect ignored")
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

  defp register_self do
    case MoyaDB.NodeRegistry.register() do
      :ok -> :ok
      {:error, reason} -> {:error, {:register, reason}}
    end
  end

  defp maybe_join_or_standalone([]) do
    with :ok <- ensure_mnesia_stopped(),
         :ok <- :mnesia.change_config(:extra_db_nodes, []),
         :ok <- create_schema_standalone(),
         :ok <- start_mnesia() do
      :ok
    end
  end

  defp maybe_join_or_standalone(peers) do
    with :ok <- ensure_mnesia_stopped(),
         :ok <- :mnesia.change_config(:extra_db_nodes, peers),
         :ok <- start_mnesia() do
      :ok
    end
  end

  defp create_schema_standalone do
    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, reason} -> {:error, {:create_schema, reason}}
    end
  end

  defp start_mnesia do
    _ = Application.ensure_loaded(:mnesia)

    case :mnesia.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, {:mnesia_start, reason}}
    end
  end

  defp ensure_registry_table_present([]) do
    create_registry_table()
  end

  defp ensure_registry_table_present(_peers) do
    case :mnesia.wait_for_tables([:schema, MoyaDB.NodeRegistry.table()], @wait_timeout) do
      :ok ->
        add_local_ram_copy()

      {:timeout, bad} ->
        {:error, {:wait_for_tables, bad}}
    end
  end

  defp create_registry_table do
    t = MoyaDB.NodeRegistry.table()

    case :mnesia.create_table(t,
           attributes: [:node, :hostname, :registered_at],
           type: :set,
           ram_copies: [node()]
         ) do
      {:atomic, :ok} ->
        :ok

      :ok ->
        :ok

      {:aborted, {:already_exists, ^t}} ->
        :ok

      {:aborted, reason} ->
        {:error, {:create_table, reason}}

      other ->
        {:error, {:create_table, other}}
    end
  end

  defp add_local_ram_copy do
    t = MoyaDB.NodeRegistry.table()

    case :mnesia.add_table_copy(t, node(), :ram_copies) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, _, _}} ->
        :ok

      {:aborted, reason} ->
        {:error, {:add_table_copy, reason}}

      other ->
        {:error, {:add_table_copy, other}}
    end
  end

  defp ensure_mnesia_stopped do
    case :mnesia.system_info(:is_running) do
      :yes ->
        case :mnesia.stop() do
          :stopped ->
            await_mnesia_stopped()

          {:error, {:not_started, _}} ->
            :ok

          other ->
            {:error, {:mnesia_stop, other}}
        end

      _ ->
        :ok
    end
  end

  defp await_mnesia_stopped do
    case :mnesia.system_info(:is_running) do
      :no ->
        :ok

      _ ->
        Process.sleep(20)
        await_mnesia_stopped()
    end
  end
end
