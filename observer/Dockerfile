FROM elixir:1.17-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache deps separately from source
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

COPY . .
RUN mix compile

ENV MIX_ENV=dev
ENV PORT=4000

EXPOSE 4000

CMD ["mix", "phx.server"]
