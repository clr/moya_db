# syntax=docker/dockerfile:1

FROM elixir:1.19.0 AS build

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

# Install Hex/Rebar and fetch deps first for better layer caching
RUN mix local.hex --force --if-missing && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

# Build release
COPY lib lib
COPY rel rel
RUN mix compile
RUN mix release


FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Runtime libraries required by Erlang/Elixir releases
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  libncurses6 \
  libstdc++6 \
  openssl \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    MOYA_DB_PORT=9000

COPY --from=build /app/_build/prod/rel/moya_db ./

EXPOSE 9000

CMD ["bin/moya_db", "start"]