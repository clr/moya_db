defmodule MoyaDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :moya_db,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :mnesia starts before our app; Cluster stops it, sets :dir, then restarts.
      extra_applications: [:logger, :mnesia],
      mod: {MoyaDB.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.0"}
    ]
  end
end
