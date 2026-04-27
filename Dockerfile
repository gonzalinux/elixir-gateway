ARG MIX_ENV=prod

FROM hexpm/elixir:1.17.3-erlang-27.1.2-alpine-3.20.3 AS builder

ARG MIX_ENV
ENV MIX_ENV=${MIX_ENV}

RUN apk add --no-cache build-base git curl tar gzip

WORKDIR /app

COPY mix.exs mix.lock ./

RUN mix local.hex --force && \
    mix local.rebar --force

RUN if [ "$MIX_ENV" = "prod" ]; then \
      mix deps.get --only prod; \
    else \
      mix deps.get; \
    fi && mix deps.compile

COPY lib lib
COPY config config
COPY priv priv

RUN mix compile && mix release && \
    elixirc priv/static_epmd/static_epmd.ex -o priv/static_epmd/

FROM alpine:3.20.3

ARG MIX_ENV=prod

RUN apk add --no-cache openssl ncurses-libs ca-certificates bash curl libstdc++ libgcc certbot certbot-dns-cloudflare

RUN addgroup -g 1000 gateway && \
    adduser -u 1000 -G gateway -s /bin/sh -D gateway

RUN mkdir -p /app /app/logs \
      /app/certbot/config \
      /app/certbot/work \
      /app/certbot/logs \
      /app/certbot/webroot/.well-known/acme-challenge && \
    chown -R gateway:gateway /app

COPY --from=builder --chown=gateway:gateway /app/_build/${MIX_ENV}/rel/elixirgateway /app
COPY --from=builder --chown=gateway:gateway /app/priv/static_epmd/Elixir.StaticEpmd.beam /app/static_epmd/Elixir.StaticEpmd.beam
COPY --from=builder --chown=gateway:gateway /app/priv/gateway.yaml /app/priv/gateway.yaml
COPY --chown=gateway:gateway script/docker_entrypoint.sh /app/docker_entrypoint.sh

RUN chmod +x /app/docker_entrypoint.sh

WORKDIR /app
USER gateway

ENV HOME=/app

EXPOSE 4000 4001 4002 9100-9200

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

CMD ["/app/docker_entrypoint.sh"]
