# ExGateway Setup Guide

Complete configuration and deployment instructions for ExGateway.

## Configuration

### Domain Mapping
Edit your configuration file to map domains to internal services:

```elixir
config :exgateway, :gateway,
  services: %{
    "api.example.com" => "http://192.168.1.10:8080",
    "admin.example.com" => "https://192.168.1.11:8443"
  },
  rate_limit: [
    requests_per_minute: 100,
    cleanup_interval: :timer.minutes(1)
  ]
```

### SSL/TLS Configuration

ExGateway uses SiteEncrypt for all SSL certificate management.

#### Production: Let's Encrypt
For automatic SSL certificate management:

**Prerequisites**: Certbot must be installed on the system:
```bash
# Install certbot using the Makefile
make install-certbot

# Or install manually (visit https://certbot.eff.org/instructions for your OS)
```

**Configuration**:
```bash
# Required environment variables
export LETSENCRYPT_DOMAINS="api.yourdomain.com,service1.yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"

# Optional: Use staging for testing
export LETSENCRYPT_STAGING="true"
```

#### Development: Auto-generated Certificates
In development, SiteEncrypt automatically generates self-signed certificates - no configuration needed.

See [LETSENCRYPT_SETUP.md](LETSENCRYPT_SETUP.md) for complete Let's Encrypt configuration.

### Rate Limiting
Rate limiting is applied per user based on:
1. `X-User-ID` header (if present)
2. `Authorization` header (hashed for identification)
3. Client IP address (fallback)

## Usage

### HTTP Requests
All HTTP requests are automatically proxied:
```bash
curl -H "Host: api.example.com" http://localhost:4000/users
# Routes to: http://192.168.1.10:8080/users
```

### WebSocket Connections
WebSocket connections via `/socket` endpoint:
```javascript
const socket = new Phoenix.Socket("/socket", {
  params: { host: "api.example.com" }
})
```

## Monitoring & Metrics

Access monitoring interfaces:
- **Prometheus metrics**: `http://localhost:4000/metrics` (protected by basic auth in production)
- **LiveDashboard**: `http://localhost:4000/dev/dashboard` (development only)

Available metrics:
- Request counts and response times by domain
- Rate limiting violations  
- Connection pool status
- SSL certificate status
- Finch HTTP client metrics

## Security Configuration

### Rate Limiting
Configure rate limits per user:
```elixir
config :exgateway, :gateway,
  rate_limit: [
    requests_per_minute: 100,
    cleanup_interval: :timer.minutes(1)
  ]
```

### Headers & Security
- All headers are properly sanitized during proxying
- No sensitive information is logged
- End-to-end connection security maintained
- CORS headers passed through from backend services