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
mix deps.get
mix compile

# Check if clustering is enabled
if [ "$CLUSTER_ENABLED" = "true" ]; then
    echo "Starting server with clustering enabled..."

    # Auto-detect NODE_IP if not set
    if [ -z "$NODE_IP" ]; then
        echo "NODE_IP not set, attempting auto-detection..."

        # Use the Mix task to detect IP (suppress stderr to avoid log pollution)
        NODE_IP=$(mix elixir_gateway.detect_ip 2>/dev/null)

        # If detection failed, the Mix task will exit with error
        if [ $? -ne 0 ] || [ -z "$NODE_IP" ]; then
            echo "ERROR: Could not auto-detect NODE_IP."
            echo "Please set NODE_IP explicitly in your $ENV_FILE:"
            echo "  NODE_IP=\"your.server.ip.address\""
            exit 1
        fi

        echo "Auto-detected NODE_IP: $NODE_IP"
    fi

    elixir --name "$NODE_NAME@$NODE_IP" \
        --erl "-start_epmd false -epmd_module fixed_port_epmd -proto_dist inet_tls -ssl_dist_optfile $(pwd)/priv/ssl_dist.conf -kernel inet_dist_listen_min $CLUSTER_PORT inet_dist_listen_max $CLUSTER_PORT" \
        -S mix phx.server
else
    echo "Starting server..."
    elixir -S mix phx.server
fi
