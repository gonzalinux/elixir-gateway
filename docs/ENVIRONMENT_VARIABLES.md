# Environment Variables Reference

This document provides comprehensive documentation for all environment variables used in ElixirGateway.

## Table of Contents

- [Required Variables](#required-variables)
- [SSL/TLS Configuration](#ssltls-configuration)
- [Application Configuration](#application-configuration)
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

DNS query for automatic node discovery in clustered deployments.

```bash
# Kubernetes headless service
DNS_CLUSTER_QUERY="elixirgateway.default.svc.cluster.local"

# Docker Swarm service
DNS_CLUSTER_QUERY="elixirgateway"
```

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

1. **Never commit secrets** to version control
2. **Use staging environment** for Let's Encrypt testing
3. **Set PHX_SERVER=true** in production deployments
4. **Use persistent storage** for SSL certificates
5. **Monitor certificate expiration** (Let's Encrypt auto-renews)
6. **Set appropriate DNS_CLUSTER_QUERY** for clustered deployments

## See Also

- [Docker Deployment Guide](DOCKER.md)
- [Let's Encrypt Setup Guide](LETSENCRYPT_SETUP.md)
- [General Setup Instructions](SETUP.md)
