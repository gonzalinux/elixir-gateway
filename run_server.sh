#!/bin/bash
# Helper script to run ElixirGateway server on Unix/Linux/macOS
# Usage: ./run_server.sh [env_file]
# Example: ./run_server.sh .env

ENV_FILE="${1:-.env}"

# Load environment variables from file if it exists
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment from $ENV_FILE..."
    # Export all non-comment, non-empty lines (strip inline comments)
    export $(grep -vE '^\s*#|^\s*$' "$ENV_FILE" | sed 's/#.*$//' | xargs)
fi

# Check if clustering is enabled
if [ "$CLUSTER_ENABLED" = "true" ]; then
    echo "Starting server with clustering enabled..."
    elixir --name "$NODE_NAME@$NODE_IP" \
        --erl "-proto_dist inet_tls -ssl_dist_optfile $(pwd)/priv/ssl_dist.conf -kernel inet_dist_listen_min $CLUSTER_PORT inet_dist_listen_max $CLUSTER_PORT" \
        -S mix phx.server
else
    echo "Starting server..."
    elixir -S mix phx.server
fi
