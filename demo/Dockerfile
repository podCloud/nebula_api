FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.19.1

RUN apk add --no-cache git build-base

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app
COPY demo-entrypoint.sh /demo-entrypoint.sh
RUN chmod +x /demo-entrypoint.sh

ENTRYPOINT ["/demo-entrypoint.sh"]
