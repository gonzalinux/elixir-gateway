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

### CERT_DB_FOLDER
**Type:** String (file path)
**Required:** No
**Default:** "/etc/elixirgateway/certs"
**Used in:** `config/prod.exs:31`

Alternative certificate storage path used in production configuration.

```bash
CERT_DB_FOLDER="/opt/ssl/certs"
```

## Application Configuration

### PHX_SERVER
**Type:** Boolean ("true" or any other value)
**Required:** No
**Default:** Not set
**Used in:** `config/runtime.exs:19`

Starts the Phoenix server automatically when set to "true". Useful for releases and containers.

```bash
# Auto-start server (recommended for production)
PHX_SERVER="true"
```

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

### PORT
**Type:** Integer
**Required:** No
**Default:** 4442
**Used in:** `config/runtime.exs:37`

HTTP port for the gateway to listen on.

```bash
# Default production port
PORT="4442"

# Custom port
PORT="8080"
```

### DNS_CLUSTER_QUERY
**Type:** String
**Required:** No
**Default:** None (clustering disabled)
**Used in:** `config/runtime.exs:39`, `lib/elixir_gateway/application.ex:13`

DNS query for automatic node discovery in clustered deployments (Kubernetes/Swarm).

**Note:** This is different from Partisan clustering (see Clustering Configuration section).

```bash
# Kubernetes headless service
DNS_CLUSTER_QUERY="elixirgateway.default.svc.cluster.local"

# Docker Swarm service
DNS_CLUSTER_QUERY="elixirgateway"
```

## Clustering Configuration

ElixirGateway supports high-availability clustering using Partisan for encrypted peer-to-peer communication and automatic failover. See [CLUSTERING.md](CLUSTERING.md) for complete setup guide.

### CLUSTER_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/cluster/supervisor.ex:19`

Enable Partisan clustering for high availability and automatic failover.

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

Port for Partisan cluster communication. Must be accessible between nodes.

```bash
CLUSTER_PORT="9100"
```

### CLUSTER_PEERS
**Type:** String (comma-separated)
**Required:** Yes (if clustering enabled)
**Default:** Empty
**Used in:** `lib/elixir_gateway/cluster/manager.ex:58`

Comma-separated list of peer addresses in `host:port` format.

```bash
# Single peer
CLUSTER_PEERS="gateway-b.example.com:9100"

# Multiple peers
CLUSTER_PEERS="gateway-b.example.com:9100,gateway-c.example.com:9100"

# Empty for nodes that only accept connections (cloud server with static IP)
CLUSTER_PEERS=""
```

**Asymmetric Setup:** For cloud + home deployments:
- Cloud node: `CLUSTER_PEERS=""` (accepts connections only)
- Home node: `CLUSTER_PEERS="cloud.example.com:9100"` (initiates connection)

### DNS_FAILOVER_ENABLED
**Type:** Boolean ("true" or "false")
**Required:** No
**Default:** "false"
**Used in:** `lib/elixir_gateway/cluster/supervisor.ex:53`

Enable automatic DNS updates when cluster peers fail. Requires clustering to be enabled.

```bash
DNS_FAILOVER_ENABLED="true"
```

### DDNS_PASS_*
**Type:** String
**Required:** Yes (if DNS failover enabled)
**Default:** None
**Used in:** Various (per domain configuration)

Namecheap Dynamic DNS passwords for each domain. Replace `*` with your domain name.

```bash
# Example for example.com
DDNS_PASS_EXAMPLE_COM="your-namecheap-ddns-password"

# Example for another domain
DDNS_PASS_MYSITE_ORG="another-ddns-password"
```

**Setup:** Enable Dynamic DNS in Namecheap dashboard (Domain → Advanced DNS → Dynamic DNS).

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

## Development & Debugging

Logging configuration is managed through `config/config.exs` and is currently hardcoded. Performance settings like HTTP client pool sizes are also configured in the application code rather than through environment variables.

## Docker Environment

When running in Docker, these variables arwe typically set in:

```dockerfile
# Set in Dockerfile
ENV PHX_SERVER=true
ENV PORT=4000
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
  PHX_SERVER: "true"
  PORT: "4000"
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
export CERT_DB_FOLDER="/opt/certs"
```

### Port Conflicts

Check for port conflicts before starting:

```bash
# Check if port is in use
netstat -tulpn | grep :4442

# Or use a different port
export PORT=8080
```

## Best Practices

1. **Never commit secrets** to version control (SECRET_KEY_BASE, CLUSTER_SECRET, DDNS passwords)
2. **Use staging environment** for Let's Encrypt testing
3. **Set PHX_SERVER=true** in production deployments
4. **Use persistent storage** for SSL certificates
5. **Monitor certificate expiration** (Let's Encrypt auto-renews)
6. **Generate strong secrets** using provided tools (mix tasks, openssl)
7. **Use asymmetric clustering** for cloud + home setups (cloud accepts, home initiates)
8. **Set NODE_IP explicitly** on cloud servers with static IPs
9. **Keep firewall ports open** for cluster communication (default: 9100)

## See Also

- [Clustering Guide](CLUSTERING.md) - High availability setup with Partisan
- [Docker Deployment Guide](DOCKER.md)
- [Let's Encrypt Setup Guide](LETSENCRYPT_SETUP.md)
- [General Setup Instructions](SETUP.md)
