# Environment Variables Reference

This document provides comprehensive documentation for all environment variables used in ElixirGateway.

## Table of Contents

- [Required Variables](#required-variables)
- [SSL/TLS Configuration](#ssltls-configuration)
- [Application Configuration](#application-configuration)
- [Clustering Configuration](#clustering-configuration)
- [Load Distribution Configuration](#load-distribution-configuration)
- [Metrics Configuration](#metrics-configuration)
- [Development & Debugging](#development--debugging)

## Required Variables

### SECRET_KEY_BASE
**Type:** String (64+ character hex)
**Required:** Yes (Production only)
**Default:** None
**Used in:** `config/runtime.exs:30`

Secret key used for signing cookies and sessions. Required in production.

```bash
# Generate a new secret key
mix phx.gen.secret

# Example
SECRET_KEY_BASE="your-64-character-secret-key-here"
```

**Security Note:** Never commit this value to version control. Use a secure random generator.

## SSL/TLS Configuration

### GATEWAY_CONFIG_FILE
**Type:** String (file path)
**Required:** No
**Default:** `priv/gateway.yaml`
**Used in:** `lib/elixir_gateway/config_loader.ex`

Path to a YAML configuration file that defines services, SSL, and DDNS settings. When this file exists it takes precedence over `GATEWAY_SERVICES` and `LETSENCRYPT_DOMAINS`. See `priv/gateway.yaml.example` for the full schema.

```bash
GATEWAY_CONFIG_FILE=/etc/elixir_gateway/gateway.yaml
```

The file supports `${VAR_NAME}` substitution for secrets:
```yaml
services:
  myapp:
    target: http://192.168.1.10:4000
    domains:
      - "*.myapp.com"
      - myapp.com
    ssl: true          # cert + force HTTPS redirect (default)
    ddns:
      provider: namecheap
      record: "@"
      domain: myapp.com
      token: "${MYAPP_DDNS_TOKEN}"
```

To allow HTTP alongside HTTPS (cert without redirect):
```yaml
ssl:
  enabled: true
  force_https: false
```

### LETSENCRYPT_DOMAINS
**Type:** String (comma-separated)
**Required:** No
**Default:** Empty (SSL disabled)
**Used in:** `lib/elixir_gateway/config_loader.ex`

Comma-separated list of domains for Let's Encrypt SSL certificates. Only used when `GATEWAY_CONFIG_FILE` is not set. When using `gateway.yaml`, SSL domains are derived automatically from services with `ssl: true`.

```bash
# Single domain
LETSENCRYPT_DOMAINS="api.yourdomain.com"

# Multiple domains
LETSENCRYPT_DOMAINS="api.yourdomain.com,app.yourdomain.com,gateway.yourdomain.com"
```

### LETSENCRYPT_EMAIL
**Type:** String (email address)
**Required:** Yes (if using Let's Encrypt)
**Default:** None
**Used in:** `lib/elixir_gateway/site_encrypt.ex:27`

Email address for Let's Encrypt account registration and notifications.

```bash
LETSENCRYPT_EMAIL="admin@yourdomain.com"
```

### LETSENCRYPT_STAGING
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/site_encrypt.ex:41`

Use Let's Encrypt staging environment for testing. Staging certificates are not trusted but have higher rate limits.

```bash
# Use for testing SSL setup
LETSENCRYPT_STAGING="true"

# Use for production
LETSENCRYPT_STAGING="false"
```

### SITE_ENCRYPT_DB
**Type:** String (file path)
**Required:** No
**Default:** "priv/certs"
**Used in:** `lib/elixir_gateway_web/endpoint.ex:20`

Directory path for storing SSL certificates and keys.

```bash
# Development
SITE_ENCRYPT_DB="priv/certs"

# Production (persistent storage)
SITE_ENCRYPT_DB="/etc/elixirgateway/certs"
```

### ACME_SERVER_PORT
**Type:** Integer
**Required:** No
**Default:** 4005
**Used in:** `lib/elixir_gateway_web/endpoint.ex:26`

Port for SiteEncrypt's internal ACME server in development and test environments. This is the server that issues self-signed certificates locally, not the HTTP listener port.

```bash
# Default internal ACME server port
ACME_SERVER_PORT="4005"

# Custom port (useful to avoid conflicts in CI)
ACME_SERVER_PORT="5005"
```

**Note:** This only applies to dev and test environments. Production uses Let's Encrypt's external ACME servers.

## Application Configuration

### PHX_HOST
**Type:** String (hostname or IP)
**Required:** No
**Default:** "0.0.0.0"
**Used in:** `config/runtime.exs:36`

Host/IP address to bind the HTTP server to.

```bash
# Bind to all interfaces (default)
PHX_HOST="0.0.0.0"

# Bind to specific IP
PHX_HOST="192.168.1.10"

# Localhost only
PHX_HOST="127.0.0.1"
```

### HTTP_PORT
**Type:** Integer
**Required:** No
**Default:** 4004 (dev), 4000 (prod)
**Used in:** `config/runtime.exs:20`, `config/dev.exs:13`, `config/prod.exs`

HTTP port for ACME challenges (Let's Encrypt) and optional HTTP access. Can be overridden in all environments (dev, test, prod).

```bash
# Override in development
HTTP_PORT="8080" mix phx.server

# Production default
HTTP_PORT="4000"

# Use standard HTTP port (requires root/capabilities)
HTTP_PORT="80"
```

### HTTPS_PORT
**Type:** Integer
**Required:** No
**Default:** 4003 (dev), 4001 (prod)
**Used in:** `config/runtime.exs:28`, `config/dev.exs:17`, `config/prod.exs`

HTTPS port for secure gateway traffic. Can be overridden in all environments (dev, test, prod).

```bash
# Override in development
HTTPS_PORT="8443" mix phx.server

# Production default
HTTPS_PORT="4001"

# Use standard HTTPS port (requires root/capabilities)
HTTPS_PORT="443"
```

### DNS_CLUSTER_QUERY
**Type:** String
**Required:** No
**Default:** None (clustering disabled)
**Used in:** `config/runtime.exs:39`, `lib/elixir_gateway/application.ex:13`

DNS query for automatic node discovery in clustered deployments (Kubernetes/Swarm).

**Note:** This is different from distributed Erlang clustering (see Clustering Configuration section).

```bash
# Kubernetes headless service
DNS_CLUSTER_QUERY="elixirgateway.default.svc.cluster.local"

# Docker Swarm service
DNS_CLUSTER_QUERY="elixirgateway"
```

## Clustering Configuration

ElixirGateway supports high-availability clustering using distributed Erlang for encrypted peer-to-peer communication and automatic failover. See [CLUSTERING.md](CLUSTERING.md) for complete setup guide.

### CLUSTER_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/cluster/supervisor.ex:19`

Enable distributed Erlang clustering for high availability and automatic failover.

```bash
CLUSTER_ENABLED="true"
```

### CLUSTER_SECRET
**Type:** String (64-character hex)
**Required:** Yes (if clustering enabled)
**Default:** None
**Used in:** `lib/elixir_gateway/cluster/manager.ex:59`

Shared secret for encrypted communication between cluster nodes. All nodes must use the same secret.

```bash
# Generate with mix task
mix elixir_gateway.gen.cluster_secret

# Or with openssl
openssl rand -hex 32

# Example
CLUSTER_SECRET="a1b2c3d4e5f6...64-characters-total"
```

**Security Note:** Keep this secret secure. Anyone with this secret can join your cluster.

### NODE_NAME
**Type:** String
**Required:** Yes (if clustering enabled)
**Default:** None
**Used in:** `lib/elixir_gateway/cluster/manager.ex:57`

Unique name for this node in the cluster. Each node must have a different name.

```bash
# Cloud node
NODE_NAME="gateway-cloud"

# Home node
NODE_NAME="gateway-home"
```

### NODE_IP
**Type:** String (IP address)
**Required:** No
**Default:** Auto-detected
**Used in:** `lib/elixir_gateway/cluster/manager.ex:317`

IP address for this node. If not set, the node will auto-detect its public IP (via ipify.org), falling back to local IP if needed.

```bash
# Explicit IP (recommended for cloud servers)
NODE_IP="203.0.113.10"

# Auto-detect (recommended for home servers with dynamic IP)
# NODE_IP=""  # or omit entirely
```

**Node Naming:** Nodes are named using the format `name@ip` (e.g., `gateway-cloud@203.0.113.10`).

### CLUSTER_PORT
**Type:** Integer
**Required:** No
**Default:** 9100
**Used in:** `lib/elixir_gateway/cluster/manager.ex:60`

Port for distributed Erlang cluster communication. Must be accessible between nodes.

```bash
CLUSTER_PORT="9100"
```

### CLUSTER_PEERS
**Type:** String (comma-separated)
**Required:** Yes (if clustering enabled)
**Default:** Empty
**Used in:** `lib/elixir_gateway/cluster/manager.ex:58`

Comma-separated list of peer addresses in `node_name@host:port` format.

```bash
# Single peer
CLUSTER_PEERS="gateway-b@gateway-b.example.com:9100"

# Multiple peers
CLUSTER_PEERS="gateway-b@192.168.1.100:9100,gateway-c@192.168.1.101:9100"

# Empty for nodes that only accept connections (cloud server with static IP)
CLUSTER_PEERS=""
```

**Asymmetric Setup (Recommended):** For cloud + home deployments:
- Home node (Primary): `CLUSTER_PEERS="gateway-cloud@cloud.example.com:9100"` (knows cloud's static IP, initiates connection)
- Cloud node (Secondary): `CLUSTER_PEERS=""` (accepts connections only, doesn't need to know home's dynamic IP)

### IS_PRIMARY
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** Auto-detected from DNS failover configuration
**Used in:** `lib/elixir_gateway/cluster/certificate_manager.ex:228` and `lib/elixir_gateway/cluster/dns_failover.ex:282`

Explicitly designate this node as primary (generates SSL certificates, manages DNS) or secondary (receives certificates).

```bash
# Force as primary (generates Let's Encrypt certificates, manages DNS failover)
IS_PRIMARY="true"

# Force as secondary (receives certificates from primary, doesn't manage DNS)
IS_PRIMARY="false"

# Auto-detect (recommended)
# IS_PRIMARY=""  # or omit entirely
```

**Auto-detection Logic:**
- DNS failover enabled (has domains configured) → Primary role
- DNS failover disabled or no domains → Secondary role

**Typical Setup:**
- Primary (home server): Has `DDNS_DOMAINS` configured, manages DNS failover when cloud fails
- Secondary (cloud servers): No `DDNS_DOMAINS`, just handles traffic

**Use Case:** In a distributed cluster with the same DNS/domain on both nodes, only the primary should contact Let's Encrypt to avoid duplicate ACME challenges and rate limits. The secondary receives certificates via encrypted distributed Erlang RPC.

### CERT_SYNC_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "true"
**Used in:** `lib/elixir_gateway/cluster/certificate_manager.ex:99`

Enable or disable SSL certificate synchronization between cluster nodes.

```bash
# Enable certificate sync (default when clustering enabled)
CERT_SYNC_ENABLED="true"

# Disable certificate sync
CERT_SYNC_ENABLED="false"
```

**Note:** Certificate sync is automatically enabled when clustering is enabled. Only disable this if you're managing certificates separately on each node.

### DNS_FAILOVER_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/cluster/supervisor.ex:53`

Enable automatic DNS updates when cluster peers fail. Requires clustering to be enabled.

```bash
DNS_FAILOVER_ENABLED="true"
```

### DNS_FAILOVER_TIMEOUT
**Type:** Integer (seconds)
**Required:** No
**Default:** 5
**Used in:** `config/runtime.exs`

Seconds to wait after cluster peers become unhealthy before triggering a DNS failover. If peers recover within this window, the failover is cancelled.

```bash
DNS_FAILOVER_TIMEOUT="30"
```

### PUBLIC_IP_STATIC
**Type:** String (IP address)
**Required:** No
**Default:** Auto-detect using ipify.org
**Used in:** DNS failover configuration

Static public IP to use for DNS updates instead of auto-detection.

```bash
# Use specific IP for DNS failover (recommended for cloud)
PUBLIC_IP_STATIC="203.0.113.10"

# Auto-detect (recommended for home with dynamic IP)
# PUBLIC_IP_STATIC=""  # or omit
```

### DDNS_DOMAINS
**Type:** String (formatted)
**Required:** Yes (if DNS failover enabled)
**Default:** None
**Format:** `host:domain:password,host:domain:password,...`

Comma-separated list of domains to update on failover.

```bash
# Single domain (root)
DDNS_DOMAINS="@:example.com:your-ddns-password"

# Multiple subdomains
DDNS_DOMAINS="@:example.com:pass1,api:example.com:pass1,www:example.com:pass1"

# Multiple domains
DDNS_DOMAINS="@:example.com:pass1,@:mysite.org:pass2"
```

**Format:**
- `@` = root domain (example.com)
- `api` = subdomain (api.example.com)
- Use same password for all hosts under one domain

## Load Distribution Configuration

Active-active load distribution enables intelligent traffic distribution across multiple cluster nodes based on configurable weights. When enabled, the primary node receives all DNS traffic and distributes load proportionally across connected nodes. See [CLUSTERING.md](CLUSTERING.md#active-active-load-distribution) for complete setup guide.

### LOAD_DISTRIBUTION_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/cluster/supervisor.ex`, `lib/elixir_gateway_web/plugs/load_distribution_router.ex`

Enable active-active load distribution across cluster nodes. Requires clustering to be enabled.

```bash
# Enable on primary node (home server that receives DNS traffic)
LOAD_DISTRIBUTION_ENABLED="true"

# Disable on secondary nodes (they just accept forwarded requests)
LOAD_DISTRIBUTION_ENABLED="false"
```

**Architecture:**
- Primary node receives all DNS traffic
- Primary distributes load based on weights via RPC
- Secondary nodes accept and process forwarded requests
- Session affinity is maintained across requests

### NODE_WEIGHT
**Type:** Integer
**Required:** No
**Default:** 70
**Used in:** `lib/elixir_gateway/cluster/load_distributor.ex`

Weight (capacity points) for this node. Each node in the cluster declares its own weight based on its hardware capacity. Traffic is distributed proportionally across all active nodes based on their declared weights.

When nodes connect to the cluster, they automatically share their weights via RPC. The primary node (receiving DNS traffic) uses these weights to calculate traffic distribution.

```bash
# Home server (high capacity)
NODE_WEIGHT="70"

# Cloud server (medium capacity)
NODE_WEIGHT="30"

# Small cloud server (lower capacity)
NODE_WEIGHT="15"
```

**Weight Distribution Examples:**
- Single node: 70 points = 100% (all traffic local)
- Home (70) + Cloud1 (30): Total 100 points → 70% / 30% distribution
- Home (70) + Cloud1 (30) + Cloud2 (15): Total 115 points → 60.9% / 26.1% / 13% distribution

**How It Works:**
- Each node sets `NODE_WEIGHT` based on its actual capacity
- On cluster connection, nodes exchange weights automatically via RPC
- No centralized configuration needed
- Add/remove nodes without updating other nodes' configs

### MIN_REQ_THRESHOLD
**Type:** Integer
**Required:** No
**Default:** 20
**Used in:** `lib/elixir_gateway/cluster/load_distributor.ex`

Minimum requests per minute before load distribution activates. Below this threshold, all traffic stays on the primary node to avoid RPC overhead during low traffic periods.

```bash
# Default threshold
MIN_REQ_THRESHOLD="20"

# Higher threshold for more local processing
MIN_REQ_THRESHOLD="50"

# Lower threshold for earlier distribution
MIN_REQ_THRESHOLD="10"
```

**Behavior:**
- **Below threshold**: All requests processed locally on primary
- **Above threshold**: New sessions distributed based on weights
- **Existing sessions**: Always routed to original node (affinity preserved)

### Complete Load Distribution Example

**Primary Server (Home) - Receives DNS traffic, distributes load:**
```bash
# Clustering
CLUSTER_ENABLED="true"
CLUSTER_SECRET="your-64-char-secret"
NODE_NAME="gateway-home"
CLUSTER_PEERS="cloud1.example.com:9100,cloud2.example.com:9100"
DNS_FAILOVER_ENABLED="true"
DDNS_DOMAINS="@:example.com:password"

# Load Distribution
LOAD_DISTRIBUTION_ENABLED="true"
NODE_WEIGHT="70"
MIN_REQ_THRESHOLD="20"
```

**Secondary Server (Cloud1) - Shares load:**
```bash
# Clustering
CLUSTER_ENABLED="true"
CLUSTER_SECRET="your-64-char-secret"
NODE_NAME="gateway-cloud1"
CLUSTER_PEERS=""  # Empty - accepts connections only
IS_PRIMARY="false"

# Load Distribution - enabled with medium capacity weight
LOAD_DISTRIBUTION_ENABLED="true"
NODE_WEIGHT="30"
MIN_REQ_THRESHOLD="20"
```

**Secondary Server (Cloud2) - Shares load:**
```bash
# Clustering
CLUSTER_ENABLED="true"
CLUSTER_SECRET="your-64-char-secret"
NODE_NAME="gateway-cloud2"
CLUSTER_PEERS=""  # Empty - accepts connections only
IS_PRIMARY="false"

# Load Distribution - enabled with lower capacity weight
LOAD_DISTRIBUTION_ENABLED="true"
NODE_WEIGHT="15"
MIN_REQ_THRESHOLD="20"
```

### Monitoring Load Distribution

After enabling load distribution, monitor these Prometheus metrics:

```bash
# Request distribution per node
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep load_distribution_request_total

# Active node weights
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep load_distribution_node_weight

# Total active weight
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep load_distribution_total_weight

# RPC forwarding latency
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep rpc_forward_duration
```

**Available Metrics:**
- `elixirgateway_load_distribution_request_total{target_node}` - Requests per node
- `elixirgateway_load_distribution_node_weight{node_name}` - Weight per node
- `elixirgateway_load_distribution_total_weight` - Sum of active weights
- `elixirgateway_load_distribution_enabled` - Feature status (1=on, 0=off)
- `elixirgateway_load_distribution_below_threshold` - Traffic threshold status
- `elixirgateway_rpc_forward_duration_milliseconds{destination_node,status}` - RPC latency

## Metrics Configuration

### METRICS_AUTH_TOKEN
**Type:** String
**Required:** No
**Default:** None (uses IP-based authentication)
**Used in:** `lib/elixir_gateway_web/plugs/metrics_auth_plug.ex`

Authentication token for protecting the `/metrics` Prometheus endpoint.

**Behavior:**
- **If set**: Requires Bearer token authentication for all requests to `/metrics`, regardless of IP address
- **If not set**: Falls back to IP-based authentication (only allows private network IPs)

```bash
# Generate a secure token
mix phx.gen.secret

# Or using openssl
openssl rand -hex 32

# Example
METRICS_AUTH_TOKEN="your-generated-secret-token-here"
```

**Usage:**

Access metrics with authentication:
```bash
# With token
curl -H "Authorization: Bearer your-token" https://gateway.com/metrics

# From private network (when no token is configured)
curl http://192.168.1.10:4000/metrics
```

**Security Notes:**
- Token authentication takes precedence over IP-based authentication when configured
- Use a strong, randomly-generated token (minimum 32 characters recommended)
- Never commit the token to version control
- Recommended for production deployments, especially in cloud environments

### RATE_LIMIT_USER
**Type:** Integer
**Required:** No
**Default:** 100
**Used in:** `lib/elixir_gateway_web/plugs/rate_limiter.ex`

Maximum number of requests per minute allowed per authenticated user or authorization token.

```bash
# Default (100 requests per minute per user)
RATE_LIMIT_USER="100"

# Higher limit for production
RATE_LIMIT_USER="1000"

# Very high limit for testing
RATE_LIMIT_USER="10000"
```

**Notes:**
- Users are identified by `X-User-ID` header, `Authorization` header, or fall back to IP address
- Exceeding this limit returns HTTP 429 (Too Many Requests)
- Limit is per-user per-minute with a 60-second rolling window

### RATE_LIMIT_IP
**Type:** Integer
**Required:** No
**Default:** 500
**Used in:** `lib/elixir_gateway_web/plugs/rate_limiter.ex`

Maximum number of requests per minute allowed per IP address (secondary limit after user-based limiting).

```bash
# Default (500 requests per minute per IP)
RATE_LIMIT_IP="500"

# Higher limit for production with many users behind NAT
RATE_LIMIT_IP="5000"

# Very high limit for testing
RATE_LIMIT_IP="100000"
```

**Notes:**
- IP-based limit is checked after user-based limit
- Helps prevent abuse when multiple users share the same authentication
- Uses `X-Forwarded-For` header when behind proxy

### BOT_BLOCKER_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "true"
**Used in:** `lib/elixir_gateway_web/plugs/bot_blocker.ex`

Enable automatic blocking of malicious bots and vulnerability scanners.

```bash
# Enable (recommended for production)
BOT_BLOCKER_ENABLED="true"

# Disable (for testing/debugging)
BOT_BLOCKER_ENABLED="false"
```

**What it blocks:**
- PHP file requests (`.php`, `.asp`, `.aspx`)
- WordPress exploit attempts (`wp-admin`, `wp-config`, etc.)
- Database admin tools (`phpmyadmin`, `adminer`)
- Environment file access (`.env`, `.git`)
- Common backdoor/shell patterns

**Behavior:**
- IPs are blocked immediately upon first suspicious request
- Blocked IPs receive HTTP 403 (Forbidden)
- Block duration controlled by `BOT_BLOCK_DURATION`

### BOT_BLOCK_DURATION
**Type:** Integer (seconds)
**Required:** No
**Default:** 3600 (1 hour)
**Used in:** `lib/elixir_gateway_web/plugs/bot_blocker.ex`

Duration in seconds to block IPs that trigger the bot blocker.

```bash
# 1 hour (default)
BOT_BLOCK_DURATION="3600"

# 24 hours
BOT_BLOCK_DURATION="86400"

# 5 minutes (for testing)
BOT_BLOCK_DURATION="300"
```

**Notes:**
- Blocks are stored in ETS (memory-only, cleared on restart)
- Longer durations reduce load from persistent attackers
- Consider your server's memory if setting very long durations with many attackers

### GATEWAY_SERVICES
**Type:** String (semicolon-separated mappings)
**Required:** No
**Default:** Uses services from config files
**Used in:** `lib/elixir_gateway/config_loader.ex`

Configure domain-to-backend routing mappings. Only used when `GATEWAY_CONFIG_FILE` is not set. Prefer `gateway.yaml` for new deployments as it also supports SSL and DDNS configuration per service. When set, this **overrides** all services configured in `config/*.exs` files.

**Format:** `host=>target_url;host=>target_url;...`

```bash
# Simple example
GATEWAY_SERVICES="api.example.com=>http://localhost:8080"

# Multiple services
GATEWAY_SERVICES="api.example.com=>http://localhost:8080;app.example.com=>https://192.168.1.10:3000;seveneat.com=>http://localhost:8443"

# With default fallback
GATEWAY_SERVICES="api.example.com=>http://localhost:8080;default=>http://localhost:8000"

# With default_any (catches all unmatched domains)
GATEWAY_SERVICES="api.example.com=>http://localhost:8080;default_any=>http://localhost:8000"
```

**Notes:**
- Use `default` as a special hostname to handle requests to the gateway's own hostname
- Use `default_any` as a catch-all for any unmatched domain/host
- Target URLs must include protocol (`http://` or `https://`)
- Whitespace around `=>` and `;` is automatically trimmed
- Changes require application restart to take effect
- Useful for containerized deployments where config files are immutable

**Example Production Setup:**
```bash
GATEWAY_SERVICES="api.myapp.com=>http://api-backend:8080;app.myapp.com=>http://webapp:3000;admin.myapp.com=>http://admin:4000;default_any=>http://landing-page:80"
```

## Development & Debugging

Logging configuration is managed through `config/config.exs` and is currently hardcoded. Performance settings like HTTP client pool sizes are also configured in the application code rather than through environment variables.

## Docker Environment

When running in Docker, these variables are typically set in:

```dockerfile
# Set in Dockerfile
ENV HTTP_PORT=4000
ENV HTTPS_PORT=4001
ENV MIX_ENV=prod

# Set at runtime
-e SECRET_KEY_BASE="your-secret-key"
-e LETSENCRYPT_DOMAINS="api.yourdomain.com"
-e LETSENCRYPT_EMAIL="admin@yourdomain.com"
```

## Kubernetes Configuration

Example ConfigMap and Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: elixirgateway-secrets
data:
  SECRET_KEY_BASE: <base64-encoded-secret>
  LETSENCRYPT_EMAIL: <base64-encoded-email>

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: elixirgateway-config
data:
  HTTP_PORT: "4000"
  HTTPS_PORT: "4001"
  LETSENCRYPT_DOMAINS: "api.yourdomain.com"
  LETSENCRYPT_STAGING: "false"
  SITE_ENCRYPT_DB: "/etc/ssl/certs"
  DNS_CLUSTER_QUERY: "elixirgateway.default.svc.cluster.local"
```

## Validation and Troubleshooting

### Required Variable Checks

The application will fail to start if:
- `SECRET_KEY_BASE` is not set in production
- `LETSENCRYPT_EMAIL` is not set when `LETSENCRYPT_DOMAINS` is configured

### Certificate Storage

Ensure certificate storage directories exist and are writable:

```bash
# Create certificate directory
mkdir -p /etc/elixirgateway/certs
chown elixirgateway:elixirgateway /etc/elixirgateway/certs

# Or use environment variable to change location
export SITE_ENCRYPT_DB="/opt/certs"
```

### Port Conflicts

Check for port conflicts before starting:

```bash
# Check if ports are in use
netstat -tulpn | grep :4000   # HTTP
netstat -tulpn | grep :4001   # HTTPS

# Or use different ports
export HTTP_PORT=8080
export HTTPS_PORT=8443
```

## Best Practices

1. **Never commit secrets** to version control (SECRET_KEY_BASE, CLUSTER_SECRET, DDNS_DOMAINS)
2. **Use staging environment** for Let's Encrypt testing
3. **Use persistent storage** for SSL certificates
4. **Monitor certificate expiration** (Let's Encrypt auto-renews)
5. **Generate strong secrets** using provided tools (mix tasks, openssl)
6. **Use asymmetric clustering** for cloud + home setups (cloud accepts, home initiates)
7. **Set NODE_IP explicitly** on cloud servers with static IPs
8. **Keep firewall ports open** for cluster communication (default: 9100)
9. **Assign weights proportionally** to actual hardware capacity when using load distribution
10. **Monitor load distribution metrics** to verify traffic is distributed as expected
11. **Adjust MIN_REQ_THRESHOLD** based on your traffic patterns to optimize RPC overhead

## See Also

- [Clustering Guide](CLUSTERING.md) - High availability setup with distributed Erlang
- [Docker Deployment Guide](DOCKER.md)
- [Let's Encrypt Setup Guide](LETSENCRYPT_SETUP.md)
- [General Setup Instructions](SETUP.md)
