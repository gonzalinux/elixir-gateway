#!/bin/sh

if [ "$CLUSTER_ENABLED" = "true" ]; then
  if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -sf https://api.ipify.org || curl -sf https://ifconfig.me)
    if [ -z "$NODE_IP" ]; then
      echo "ERROR: Could not auto-detect NODE_IP. Please set it explicitly in your .env"
      exit 1
    fi
    echo "Auto-detected NODE_IP: $NODE_IP"
  fi

  PRIV_DIR=$(ls -d /app/lib/elixirgateway-*/priv | head -1)

  export RELEASE_DISTRIBUTION=name
  export RELEASE_NODE="${NODE_NAME}_${CLUSTER_PORT:-9100}@${NODE_IP}"
  export ERL_FLAGS="-pa /app/static_epmd -start_epmd false -epmd_module Elixir.StaticEpmd -proto_dist inet_tls -ssl_dist_optfile ${PRIV_DIR}/ssl_dist.conf -kernel inet_dist_listen_min ${CLUSTER_PORT:-9100} inet_dist_listen_max ${CLUSTER_PORT:-9100}"

  echo "Starting node: $RELEASE_NODE"
fi

exec ./bin/elixirgateway start
