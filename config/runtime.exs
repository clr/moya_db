import Config

if config_env() == :prod do
  port =
    System.get_env("MOYA_DB_PORT", "9000")
    |> String.to_integer()

  mnesia_root = System.get_env("MOYA_DB_MNESIA_ROOT")

  config :moya_db,
    http_port: port,
    mnesia_root: mnesia_root
end