# Docker Deployment

ElixirGateway runs as an Elixir release in a minimal Alpine container using `network_mode: host`.

## Deploy

```bash
make prod       # git pull + docker compose up -d --build
make logs       # follow logs
make stop       # stop containers
```

## Environment Variables

Create a `.env` file at the project root. All configuration is injected at container startup — no rebuild needed for env changes, just `docker compose up -d --force-recreate`.

### Required

```bash
SECRET_KEY_BASE=        # mix phx.gen.secret
GATEWAY_SERVICES=       # "host=>target;host=>target" (see below)
```

### Gateway Services

```bash
# Format: semicolon-separated host=>target mappings
GATEWAY_SERVICES="api.example.com=>http://localhost:8080;app.example.com=>http://localhost:3000;default_any=>http://localhost:8000"
```

### Common Options

```bash
HTTP_PORT=4000
HTTPS_PORT=4001
RATE_LIMIT_USER=100
RATE_LIMIT_IP=500
BOT_BLOCKER_ENABLED=true
METRICS_AUTH_TOKEN=        # optional, protects /metrics
```

### Clustering (optional)

Required when running multiple nodes. The primary node initiates connections; secondary nodes accept them.

```bash
# Both nodes
CLUSTER_ENABLED=true
CLUSTER_SECRET=            # mix elixir_gateway.gen.cluster_secret
CLUSTER_PORT=9100
NODE_NAME=serverA          # unique per node

# Primary only (knows the secondary's address)
CLUSTER_PEERS="serverB_9101@1.2.3.4"

# NODE_IP is auto-detected via curl if not set
NODE_IP=                   # optional override
```

#### How clustering works in Docker

The entrypoint (`script/docker_entrypoint.sh`) runs before the release starts. When `CLUSTER_ENABLED=true` it:
1. Auto-detects `NODE_IP` if not set
2. Sets `RELEASE_NODE` and `RELEASE_DISTRIBUTION=name` so the VM starts in distributed mode
3. Sets `ERL_FLAGS` with TLS distribution flags (`-proto_dist inet_tls`, `-epmd_module Elixir.StaticEpmd`, etc.)

`StaticEpmd` is compiled into the application (via `elixirc_paths` in `mix.exs`) so it's available to the Erlang kernel at boot in embedded mode.

## MIX_ENV

```bash
# Default: prod (Elixir release, slim Alpine image)
make prod

# Dev mode (all deps, same release mechanism)
MIX_ENV=dev docker compose up -d --build
```

## Image Details

- **Builder**: `hexpm/elixir:1.17.3-erlang-27.1.2-alpine-3.20.3`
- **Runtime**: `alpine:3.20.3` + bundled ERTS (no Elixir/Mix at runtime)
- **User**: non-root `gateway` (UID 1000)
- **Network**: `host` mode (required for clustering and port binding)
- **Health check**: `GET /health` every 30s
