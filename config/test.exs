import Config

config :moya_db,
  cluster_seeds: [],
  http_port: 9100,
  mnesia_root: Path.join(System.tmp_dir!(), "moya_db_mnesia_test")
