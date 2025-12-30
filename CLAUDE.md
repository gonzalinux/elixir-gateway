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
Internet → Rate Limiter → WebSocket Upgrade Check → Domain Router → Request Forwarder
```

### Core Components

#### Plugs (Request Processing)
- **`DomainRouter`** - Maps domains to target services based on configuration
- **`RateLimiter`** - Implements rate limiting (100 req/min default, uses Hammer)
- **`RequestForwarder`** - Forwards HTTP requests using Finch client
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

#### Monitoring
- **PromEx integration** with custom gateway metrics
- **`/metrics`** endpoint for Prometheus scraping
  - Token authentication (if `METRICS_AUTH_TOKEN` env var is set)
  - IP-based authentication (fallback, allows private networks only)
- **`/dev/dashboard`** Phoenix LiveDashboard (dev only)

### Configuration Structure

Gateway services are configured in config files:
```elixir
config :elixirgateway, :gateway,
  services: %{
    "api.yourdomain.com" => "http://192.168.1.10:8080",
    "app.yourdomain.com" => "https://192.168.1.11:4000"
  },
  rate_limit: [
    requests_per_minute: 100,
    cleanup_interval: :timer.minutes(1)
  ]
```

### Key Dependencies
- **Phoenix 1.7.21** - Web framework
- **Bandit 1.5** - HTTP server
- **Finch 0.19** - HTTP client for request forwarding
- **Gun 2.0** - HTTP/WebSocket client for WebSocket proxying
- **Hammer 6.1** - Rate limiting
- **PromEx 1.9** - Prometheus metrics
- **SiteEncrypt 0.6** - Automatic SSL certificate management
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
  - Broadcast certificates to secondary nodes via Erlang RPC

- **Secondary nodes** (`IS_PRIMARY=false`):
  - Run SiteEncrypt in **manual mode** with empty domains
  - **DO NOT** attempt ACME challenges (prevents rate limiting issues)
  - Receive certificates from primary via `CertificateManager` cluster sync
  - Certificates written to same `SITE_ENCRYPT_DB` path and loaded automatically

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
