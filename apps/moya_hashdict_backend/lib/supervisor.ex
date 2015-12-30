defmodule MoyaHashdictBackend.Supervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, :ok)
  end

  @registry_name MoyaHashdictBackend.BucketRegistry
  @ets_registry_name MoyaHashdictBackend.BucketRegistry
  @bucket_supervisor_name MoyaHashdictBackend.BucketSupervisor

  def init(:ok) do
    ets = :ets.new(@ets_registry_name, [:set, :public, :named_table, {:read_concurrency, true}])

    children = [
      supervisor(MoyaHashdictBackend.BucketSupervisor, [[name: @bucket_supervisor_name]]),
      worker(MoyaHashdictBackend.BucketRegistry, [ets, @bucket_supervisor_name, [name: @registry_name]])
    ]

    supervise(children, strategy: :one_for_one)
  end
end
