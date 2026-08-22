defmodule MoyaDB.Metrics do
  @moduledoc """
  Tracks inbound API request metrics over a rolling time window.
  """

  use GenServer

  @default_window_ms 1_000
  @default_db_id "db-1"
  @default_latency_reservoir_size 1_024

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record one inbound request with status and latency."
  def record(status, latency_ms) when is_integer(status) and is_number(latency_ms) do
    GenServer.cast(__MODULE__, {:record, status, latency_ms})
  end

  @doc "Return a metrics snapshot over the active rolling window."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "Clear all collected samples."
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(_opts) do
    window_ms = Application.get_env(:moya_db, :metrics_window_ms, @default_window_ms)
    db_id = Application.get_env(:moya_db, :db_id, @default_db_id)
    latency_reservoir_size =
      Application.get_env(:moya_db, :metrics_latency_reservoir_size, @default_latency_reservoir_size)

    {:ok,
     %{
       window_ms: window_ms,
       db_id: db_id,
       status_samples: :queue.new(),
       latency_samples: :queue.new(),
       latency_reservoir_size: latency_reservoir_size
     }}
  end

  @impl true
  def handle_cast({:record, status, latency_ms}, state) do
    now = System.system_time(:millisecond)
    status_samples =
      {now, status}
      |> :queue.in(state.status_samples)
      |> prune_queue(state.window_ms, now)

    latency_samples =
      {now, latency_ms}
      |> :queue.in(state.latency_samples)
      |> prune_queue(state.window_ms, now)
      |> cap_queue(state.latency_reservoir_size)

    {:noreply, %{state | status_samples: status_samples, latency_samples: latency_samples}}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | status_samples: :queue.new(), latency_samples: :queue.new()}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = System.system_time(:millisecond)
    status_samples = prune_queue(state.status_samples, state.window_ms, now)
    latency_samples = prune_queue(state.latency_samples, state.window_ms, now)

    statuses = queue_values(status_samples)
    latencies = queue_values(latency_samples)

    response = %{
      "window_ms" => state.window_ms,
      "timestamp" => now,
      "role" => "database",
      "db_id" => state.db_id,
      "inbound" => %{
        "query_count" => length(statuses),
        "responses" => %{
          "2xx" => count_bucket(statuses, 200, 299),
          "4xx" => count_bucket(statuses, 400, 499),
          "5xx" => count_bucket(statuses, 500, 599)
        },
        "last_status" => List.last(statuses)
      },
      "health" => %{
        "ready" => true,
        "latency_ms_p50" => percentile(latencies, 50),
        "latency_ms_p95" => percentile(latencies, 95)
      }
    }

    {:reply, response, %{state | status_samples: status_samples, latency_samples: latency_samples}}
  end

  # --- Private helpers ------------------------------------------------------

  defp prune_queue(queue, window_ms, now) do
    cutoff = now - window_ms

    case :queue.peek(queue) do
      {:value, {ts, _value}} when ts < cutoff ->
        queue
        |> :queue.drop()
        |> prune_queue(window_ms, now)

      _ ->
        queue
    end
  end

  defp cap_queue(queue, max_size) do
    if :queue.len(queue) > max_size do
      queue
      |> :queue.drop()
      |> cap_queue(max_size)
    else
      queue
    end
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    size = length(sorted)
    index = trunc(Float.ceil((p / 100) * size)) - 1
    index = max(index, 0)
    value = Enum.at(sorted, index)
    Float.round(value * 1.0, 1)
  end

  defp queue_values(queue) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn {_ts, value} -> value end)
  end

  defp count_bucket(statuses, min, max) do
    Enum.count(statuses, fn status -> status >= min and status <= max end)
  end
end
