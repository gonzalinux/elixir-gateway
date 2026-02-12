# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Development
- `make setup` - Install dependencies and setup project
- `make run` - Start Phoenix server (development mode)
- `mix phx.server` - Alternative to start Phoenix server
- `mix deps.get` - Install dependencies only

### Testing
- `mix test` - Run all tests
- `mix test test/path/to/specific_test.exs` - Run a specific test file
- `mix test --only line:123` - Run test at specific line number

### SSL Certificate Management
- `make install-certbot` - Install certbot for Let's Encrypt SSL certificates

### Formatting and Code Quality
- `mix format` - Format Elixir code (standard Elixir formatter)

## Architecture Overview

ElixirGateway is a high-performance API Gateway built with Phoenix that serves as a reverse proxy with domain-based routing.

### Request Processing Pipeline
```
Internet → Bot Blocker → Rate Limiter → WebSocket Upgrade Check → Domain Router → Load Distribution Router → Request Forwarder
```

**Note**: LoadDistributionRouter is only active when load distribution is enabled. When disabled, requests flow directly from DomainRouter to RequestForwarder.

### Core Components

#### Plugs (Request Processing)
- **`DomainRouter`** - Maps domains to target services based on configuration
- **`RateLimiter`** - Implements rate limiting (100 req/min default, uses Hammer)
- **`LoadDistributionRouter`** - Routes requests across cluster nodes based on weights (optional)
  - Weight-based distribution for active-active load balancing
  - Session affinity preservation
  - Traffic threshold detection (routes locally below 20 req/min)
  - Dynamic adjustment when nodes connect/disconnect
- **`RequestForwarder`** - Forwards HTTP requests using Finch client
  - Supports large file uploads up to 20MB
  - Chunked reading (1MB chunks) with 15-second timeout per chunk
  - Multipart form data handling
  - Extended timeouts (40 seconds for large transfers)
  - RPC forwarding to remote nodes when load distribution is enabled
- **`WebSocketUpgradePlug`** - Detects and handles WebSocket upgrade requests
- **`MetricsAuthPlug`** - Protects `/metrics` endpoint with authentication

#### WebSocket Proxying
- **`EnhancedGunWebSocketHandler`** - Advanced WebSocket handler with connection pooling, automatic reconnection, and message queuing
- Bidirectional message forwarding with session preservation
- Full Phoenix LiveView support
- Connection pooling for improved performance
- Automatic reconnection with exponential backoff
- Message queuing during connection interruptions

#### Sticky Sessions (Cluster Mode)
- **`ConnectionRegistry`** - Local ETS-based session affinity with TTL
- Ensures same client always hits same backend node (critical for eventual consistency)
- Session identification: IP + (WebSocket key | cookie | X-Session-ID | nil)
- TTL-based cleanup prevents memory leaks (default: 30min inactivity)
- Configurable via `:cluster` config with `session_ttl_minutes` and `cleanup_interval_minutes`
- Monitoring: `session_count/0` and Prometheus metric `elixirgateway_session_registry_active_sessions`

#### Active-Active Load Distribution (Optional)
- **`LoadDistributor`** - Weight-based load distribution across cluster nodes
- Intelligent traffic routing: Primary node receives all DNS traffic and distributes load proportionally
- **Dynamic weight discovery**: Each node declares its own weight; no centralized configuration needed
- Weight-based allocation example (if nodes declare these weights):
  - Home node: 70 points = 60.9% traffic (with 2 clouds)
  - Cloud1 node: 30 points = 26.1% traffic
  - Cloud2 node: 15 points = 13.0% traffic
- Traffic threshold: Routes all traffic locally when below 20 req/min (configurable)
- Dynamic adjustment: Automatically recalculates weights when nodes connect/disconnect
- Session affinity: Maintains sticky sessions across requests
- RPC forwarding: Transparent request forwarding to remote nodes via Erlang RPC
- Graceful degradation: Falls back to local processing if remote node is down
- Flexible scaling: Add/remove nodes without reconfiguration (they auto-share weights via RPC)

**Configuration**:
```bash
# Each node declares its own weight based on capacity
# Home server (high capacity, receives all DNS traffic)
export LOAD_DISTRIBUTION_ENABLED=true
export NODE_WEIGHT=70
export MIN_REQ_THRESHOLD=20

# Cloud server 1 (medium capacity)
export LOAD_DISTRIBUTION_ENABLED=true
export NODE_WEIGHT=30
export MIN_REQ_THRESHOLD=20

# Cloud server 2 (lower capacity)
export LOAD_DISTRIBUTION_ENABLED=true
export NODE_WEIGHT=15
export MIN_REQ_THRESHOLD=20
```

**How It Works**:
1. DNS points to primary (home) server
2. Primary receives all traffic and makes routing decisions:
   - Below threshold (<20 req/min): All traffic stays local
   - Above threshold: New sessions distributed based on weights via RPC
   - Existing sessions: Routed to assigned node (affinity preserved)
3. Secondary nodes process forwarded requests via RPC calls
4. If secondary is down: Automatic fallback to local processing

**Monitoring**:
- `elixirgateway_load_distribution_request_total{target_node}` - Requests per node
- `elixirgateway_rpc_forward_duration_milliseconds` - RPC latency histogram
- `elixirgateway_load_distribution_node_weight{node_name}` - Current node weights
- `elixirgateway_load_distribution_total_weight` - Sum of active weights
- `elixirgateway_load_distribution_enabled` - Feature status (1=on, 0=off)
- `elixirgateway_load_distribution_below_threshold` - Traffic threshold status (1=below, 0=above)

#### Monitoring
- **PromEx integration** with custom gateway metrics
  - `elixirgateway_request_total` - Counter with labels: method, status, target_service, path, host
  - `elixirgateway_request_duration_milliseconds` - Histogram with labels: method, status, target_service, host
  - Path tracking sampled at 10% to manage cardinality
  - Cluster health metrics (peers connected, DNS failover state, session registry)
  - Load distribution metrics (node weights, request distribution, RPC latency)
- **`/metrics`** endpoint for Prometheus scraping
  - Token authentication (if `METRICS_AUTH_TOKEN` env var is set)
  - IP-based authentication (fallback, allows private networks only)
- **`/dev/dashboard`** Phoenix LiveDashboard (dev only)

### Configuration Structure

Gateway services can be configured in config files or via environment variables:

**Config file approach:**
```elixir
config :elixirgateway, :gateway,
  services: %{
    "api.yourdomain.com" => "http://192.168.1.10:8080",
    "app.yourdomain.com" => "https://192.168.1.11:4000",
    "default_any" => "http://localhost:8000"
  },
  rate_limit: [
    user_requests_per_minute: 100,
    ip_requests_per_minute: 500,
    cleanup_interval: :timer.minutes(1)
  ]
```

**Environment variable approach (recommended for production/containers):**
```bash
# Gateway service mappings
GATEWAY_SERVICES="api.example.com=>http://localhost:8080;app.example.com=>https://192.168.1.10:3000;default_any=>http://localhost:8000"

# Rate limiting
RATE_LIMIT_USER=1000
RATE_LIMIT_IP=5000

# Bot blocking
BOT_BLOCKER_ENABLED=true
BOT_BLOCK_DURATION=3600
```

**Format for GATEWAY_SERVICES:**
- Semicolon-separated mappings: `host=>target;host=>target`
- Use `default` or `default_any` as catch-all for unmatched hosts
- Whitespace around `=>` and `;` is automatically trimmed
- Overrides all config file services when set

### Key Dependencies
- **Phoenix 1.7.21** - Web framework
- **Bandit 1.5** - HTTP server
- **Finch 0.19** - HTTP client for request forwarding
- **Gun 2.0** - HTTP/WebSocket client for WebSocket proxying
- **Hammer 6.1** - Rate limiting
- **PromEx 1.9** - Prometheus metrics
- **SiteEncrypt 0.7** - Automatic SSL certificate management
- **Bypass 2.1** - HTTP client mocking for tests

### Testing Patterns

#### Test Setup Pattern
Tests use comprehensive setup/teardown for configuration:
```elixir
setup do
  original_config = Application.get_env(:elixirgateway, :gateway)
  Application.put_env(:elixirgateway, :gateway, test_config)
  on_exit(fn -> restore_or_delete_config end)
end
```

#### Testing Strategy
- **Unit tests** for each plug with edge cases
- **Mock-based testing** using Bypass for HTTP services
- **Non-async tests** for rate limiting (uses ETS)
- **Unique identifiers** in tests to avoid conflicts

### Rate Limiting Implementation
- User identification priority: `X-User-ID` header → Authorization header hash → IP address
- Returns proper HTTP 429 responses with rate limit headers
- Configurable limits with cleanup intervals

### SSL/TLS Management
- **SiteEncrypt** integration for automatic Let's Encrypt certificates
- Environment-based configuration (dev/staging/prod)
- Manual SSL configuration support

#### Distributed Cluster SSL Behavior
**IMPORTANT:** Certificate challenges are role-aware to prevent multiple nodes from attempting Let's Encrypt ACME challenges:

- **Primary nodes** (`IS_PRIMARY` not set, or peers configured):
  - Run SiteEncrypt with full ACME challenge capability
  - Generate Let's Encrypt certificates automatically
  - Broadcast certificates to secondary nodes via Erlang RPC:
    - **Automatically** when new certificates are generated
    - **Automatically** when a secondary node connects to the cluster (3-second delay to ensure SiteEncrypt initialization completes)
  - Monitor node connections to ensure new peers receive existing certificates

- **Secondary nodes** (`IS_PRIMARY=false`):
  - Run SiteEncrypt in **manual mode** with empty domains
  - **DO NOT** attempt ACME challenges (prevents rate limiting issues)
  - Receive certificates from primary via `CertificateManager` cluster sync
  - Certificates written to same `SITE_ENCRYPT_DB` path and loaded automatically
  - Automatically receive certificates upon connecting to primary (no manual sync needed)

**Role Detection:**
1. Explicit: `IS_PRIMARY=false` → Secondary (receives certs)
2. Auto-detect: `CLUSTER_PEERS` configured → Primary (generates certs)
3. Default (no clustering): Primary (generates certs)

**Configuration:**
```bash
# Primary node (home server)
export CLUSTER_PEERS="cloud-a@ip:port,cloud-b@ip:port"
# IS_PRIMARY is implicitly true

# Secondary node (cloud server)
export IS_PRIMARY=false
export CLUSTER_PEERS=""  # Empty, accepts connections
```

**Why This Matters:** Without this protection, all nodes would independently attempt ACME challenges, causing:
- Race conditions for HTTP-01 challenges
- Let's Encrypt rate limit exhaustion (5 failed authorizations/hour)
- Certificate sync becoming ineffective
- Deployment failures in containerized environments with independent storage

### WebSocket Architecture
- Transparent proxying with session preservation
- Header transformation and forwarding
- Support for Phoenix LiveView applications
- Connection lifecycle management

### Security Considerations
- Authentication required for metrics endpoint in production
- Proper header filtering during proxying (removes hop-by-hop headers)
- No sensitive information in logs
- Environment-based secret management

## Try to use with statements instead of nested case statements
