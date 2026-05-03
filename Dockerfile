FROM elixir:1.18

RUN apt-get update && apt-get install -y git make && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build hex from source (avoids TLS issues with hex.pm)
RUN git clone --depth 1 --branch v2.4.1 https://github.com/hexpm/hex.git /tmp/hex && \
    cd /tmp/hex && MIX_ENV=prod mix archive.build -o /tmp/hex.ez && \
    mix archive.install /tmp/hex.ez --force && \
    rm -rf /tmp/hex

# Build rebar3 from source
RUN git clone --depth 1 https://github.com/erlang/rebar3.git /tmp/rebar3 && \
    cd /tmp/rebar3 && ./bootstrap && \
    mix local.rebar rebar3 /tmp/rebar3/rebar3 --force && \
    rm -rf /tmp/rebar3

WORKDIR /app

COPY mix.exs mix.lock* ./
RUN mix deps.get && \
    rm -f deps/castore/lib/mix/tasks/certdata.ex && \
    mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
RUN mix compile

CMD ["mix", "run", "--no-halt"]
