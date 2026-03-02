#!/bin/sh

if [ "$CLUSTER_ENABLED" = "true" ]; then
  PRIV_DIR=$(ls -d /app/lib/elixirgateway-*/priv | head -1)

  export RELEASE_DISTRIBUTION=name
  export RELEASE_NODE="${NODE_NAME}_${CLUSTER_PORT:-9100}@${NODE_IP}"
  export ERL_FLAGS="-start_epmd false -epmd_module Elixir.StaticEpmd -proto_dist inet_tls -ssl_dist_optfile ${PRIV_DIR}/ssl_dist.conf -kernel inet_dist_listen_min ${CLUSTER_PORT:-9100} inet_dist_listen_max ${CLUSTER_PORT:-9100}"
fi

exec ./bin/elixirgateway start
