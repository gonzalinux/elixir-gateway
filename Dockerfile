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

RUN mix compile && mix release

FROM alpine:3.20.3

ARG MIX_ENV=prod

RUN apk add --no-cache openssl ncurses-libs ca-certificates bash curl libstdc++ libgcc

RUN addgroup -g 1000 gateway && \
    adduser -u 1000 -G gateway -s /bin/sh -D gateway

RUN mkdir -p /app /etc/elixirgateway/certs && \
    chown -R gateway:gateway /app /etc/elixirgateway

COPY --from=builder --chown=gateway:gateway /app/_build/${MIX_ENV}/rel/elixirgateway /app
COPY --chown=gateway:gateway script/docker_entrypoint.sh /app/docker_entrypoint.sh

# Put StaticEpmd in the release ebin so it's in the code path at boot time,
# before the kernel starts net_sup and resolves the EPMD module.
RUN EBIN=$(ls -d /app/lib/elixirgateway-*/ebin | head -1) && \
    EPMD=$(ls -d /app/lib/elixirgateway-*/priv/static_epmd | head -1) && \
    cp "${EPMD}/Elixir.StaticEpmd.beam" "${EBIN}/"

RUN chmod +x /app/docker_entrypoint.sh

WORKDIR /app
USER gateway

ENV HOME=/app

EXPOSE 4000 4001 4002

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

CMD ["/app/docker_entrypoint.sh"]
