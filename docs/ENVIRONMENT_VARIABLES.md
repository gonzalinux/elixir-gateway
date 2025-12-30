# Environment Variables Reference

This document provides comprehensive documentation for all environment variables used in ElixirGateway.

## Table of Contents

- [Required Variables](#required-variables)
- [SSL/TLS Configuration](#ssltls-configuration)
- [Application Configuration](#application-configuration)
- [Clustering Configuration](#clustering-configuration)
- [Network Configuration](#network-configuration)
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

### LETSENCRYPT_DOMAINS
**Type:** String (comma-separated)
**Required:** No
**Default:** Empty (SSL disabled)
**Used in:** `lib/elixir_gateway/site_encrypt.ex:10`

Comma-separated list of domains for Let's Encrypt SSL certificates.

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

## See Also

- [Clustering Guide](CLUSTERING.md) - High availability setup with distributed Erlang
- [Docker Deployment Guide](DOCKER.md)
- [Let's Encrypt Setup Guide](LETSENCRYPT_SETUP.md)
- [General Setup Instructions](SETUP.md)
