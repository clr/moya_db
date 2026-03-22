defmodule Mix.Tasks.Demo do
  @shortdoc "Run a MoyaDB hello-world demo"
  @moduledoc """
  Starts the application, stores a few values, queries them, and prints
  node information. Use this to verify everything is wired up correctly.

      mix demo

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n=== MoyaDB Demo ===\n")

    IO.puts("Node info:")

    MoyaDB.node_info()
    |> Enum.each(fn {k, v} -> IO.puts("  #{k}: #{inspect(v)}") end)

    IO.puts("\nStoring entries...")
    MoyaDB.put("language", "Elixir")
    MoyaDB.put("project", "MoyaDB")
    MoyaDB.put("status", :initializing)
    MoyaDB.put({:version, :major}, 0)

    IO.puts("All entries: #{inspect(MoyaDB.all())}")

    IO.puts("\nQuerying...")
    IO.puts("  language -> #{inspect(MoyaDB.get("language"))}")
    IO.puts("  missing  -> #{inspect(MoyaDB.get("missing"))}")

    IO.puts("\nDeleting 'status'...")
    MoyaDB.delete("status")
    IO.puts("  status after delete -> #{inspect(MoyaDB.get("status"))}")

    IO.puts("\nEntry count: #{map_size(MoyaDB.all())}")
    IO.puts("\nDone. MoyaDB is running. ^C to exit.\n")
  end
end
