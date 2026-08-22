# MoyaDB

Distributed key-value database built on Elixir/OTP.

Current implementation notes:

- Values are stored in-memory in a GenServer on each node.
- Value data is replicated to connected peers asynchronously.
- Mnesia is used for cluster membership metadata, not as the value store.
- Value data is not durable across node restart.
- Reconnect anti-entropy now preserves deletes and flushes with versioned tombstones and a reset watermark, but this is still not consensus-based replication.

Canonical repository:

- https://github.com/clr/moya

Related repositories:

- Deployment/orchestration: https://github.com/clr/moya_harness
- Load generator: https://github.com/clr/moya_squeezer

## Multi-service deployment

For running the full stack (`moya_db` + `moya_squeezer` manager/workers), use
the deployment harness:

- https://github.com/clr/moya_harness

This repo remains focused on the database service itself.

## Behavior and guarantees

- `POST /db/v0.1/:key` stores any JSON value under the key.
- `GET /db/v0.1/:key` returns the stored value if it is still JSON-serializable.
- `DELETE /db/v0.1/:key` removes the key in a single store operation and replicates a tombstone so reconnect does not revive stale state.
- `GET /db/v0.1/metrics` reports rolling inbound request counts and latency percentiles.

Operational caveats:

- Replication is asynchronous, so a successful write only confirms the local node has accepted the change.
- There is no consensus layer, so concurrent partitions can still produce last-writer-wins outcomes based on version order.
- Flush and delete behavior are protected against reconnect resurrection, but distributed correctness still needs staged multi-node validation under real partitions and restarts.

## Run as a managed release service (Design #3)

This project now supports clean release-based lifecycle commands via
`scripts/moya_db_service.sh`.

### 1) Build release

```bash
cd /Users/clr/moya_db
./scripts/moya_db_service.sh build
```

### 2) Start / Stop / Restart / Status

```bash
./scripts/moya_db_service.sh start
./scripts/moya_db_service.sh status
./scripts/moya_db_service.sh restart
./scripts/moya_db_service.sh stop
```

### 3) Verify API

# Create a record
```bash
curl -i -X POST http://localhost:9000/db/v0.1/greeting \\
  -H 'Content-Type: application/json' \
  -d '"hello"'
```

Expected: `200` with JSON `{"value":"hello","key":"greeting"}`.

# Read the record
```bash
curl -i http://localhost:9000/db/v0.1/greeting
```

Expected: `200` with JSON `{"value":"hello","key":"greeting"}`.

# Delete the record
```bash
curl -i -X DELETE http://localhost:9000/db/v0.1/greeting
```

Expected: `200` with JSON `{"key":"greeting","deleted":true}`.

# Confirm deletion (should return 404)
```bash
curl -i http://localhost:9000/db/v0.1/greeting
```

Expected: `404` with JSON `{"error":"key not found"}`.

## Runtime environment variables (release)

- `MOYA_DB_PORT` (default: `9000`)
- `MOYA_DB_MNESIA_ROOT` (default: unset)
- `RELEASE_NODE` (default: `moya_db@127.0.0.1`)
- `RELEASE_COOKIE` (default in `rel/env.sh.eex`: `moya_db_cookie_change_me`)

Example:

```bash
MOYA_DB_PORT=9100 \
MOYA_DB_MNESIA_ROOT=/tmp/moya_db_mnesia \
RELEASE_COOKIE=supersecret \
./scripts/moya_db_service.sh start
```

## Service manager templates

- macOS launchd template: `deploy/launchd/com.moyadb.plist`
- Linux systemd template: `deploy/systemd/moya_db.service`

Update placeholder paths/users/secrets before enabling in your environment.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `moya_db` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:moya_db, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/moya_db>.
