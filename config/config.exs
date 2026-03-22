import Config

# Seed nodes to connect to on boot (distributed Erlang names), e.g.:
#   [:"moya1@myhost", :"moya2@myhost"]
# Empty list = single-node / no remote peers to join.
config :moya_db,
  cluster_seeds: [],
  # Override to isolate Mnesia files (recommended in test.exs)
  mnesia_root: nil

import_config "#{config_env()}.exs"
