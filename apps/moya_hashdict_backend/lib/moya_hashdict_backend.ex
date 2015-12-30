defmodule MoyaHashdictBackend do
  use Application

  def start(_type, _args) do
    MoyaHashdictBackend.Supervisor.start_link
  end
end
