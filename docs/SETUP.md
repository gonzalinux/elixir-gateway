# ExGateway Setup Guide

Complete configuration and deployment instructions for ExGateway.

## Configuration

### Domain Mapping
Edit your configuration file to map domains to internal services:

```elixir
config :elixir_gateway, :gateway,
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

ExGateway provides flexible SSL certificate management suitable for Docker deployments and traditional servers.

#### Production: Automatic SSL Management
ExGateway automatically handles SSL certificates in production:

**Default Configuration** (Docker-friendly):
- Self-signed certificates generated automatically for development/testing
- No external dependencies required
- Works out-of-the-box in containerized environments

**Optional Configuration**:
```bash
# Set custom certificate storage path
export CERT_DB_FOLDER="/etc/elixirgateway/certs"
```

#### Development: Auto-generated Certificates
In development, SSL certificates are automatically generated - no configuration needed.

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
config :elixir_gateway, :gateway,
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

### Environment Variables for Production

**Required for Production:**
```bash
# Generate a secret key for production
export SECRET_KEY_BASE=$(mix phx.gen.secret)

# Optional: Set custom host and port
export PHX_HOST="yourdomain.com"
export PORT="4442"

# For Let's Encrypt SSL
export LETSENCRYPT_DOMAINS="api.yourdomain.com,service1.yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"
```

**All Available Environment Variables:**

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `SECRET_KEY_BASE` | Secret key for signing cookies and tokens | `mix phx.gen.secret` | Yes (prod) |
| `PHX_HOST` | Host for the Phoenix endpoint | `api.yourdomain.com` | Yes (prod) |
| `PORT` | HTTP port for the server | `4000` | Optional (default: 4442) |
| `PHX_SERVER` | Enable Phoenix server | `true` | Optional |
| `DNS_CLUSTER_QUERY` | DNS cluster query for distributed deployment | `api.cluster.local` | Optional |
| `CERT_DB_FOLDER` | SSL certificate storage path | `/etc/ssl/certs` | Optional |
| `LETSENCRYPT_DOMAINS` | Domains for SSL certificates | `api.example.com,app.example.com` | Required for SSL |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt registration | `admin@example.com` | Required for SSL |
| `LETSENCRYPT_STAGING` | Use Let's Encrypt staging environment | `true` | Optional |

**Security Note:**
- Development uses a hardcoded `secret_key_base` for convenience
- Production requires `SECRET_KEY_BASE` environment variable for security
- Never use development secrets in production environments

## Health Check Endpoints

ExGateway provides health check endpoints for load balancers and monitoring:

| Endpoint | Purpose | Use Case |
|----------|---------|----------|
| `/health` | General health check | Load balancer health checks |
| `/health/ready` | Readiness probe | Kubernetes readiness probe |
| `/health/live` | Liveness probe | Kubernetes liveness probe |

### Health Check Responses

**Healthy response (200):**
```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T00:00:00Z",
  "version": "1.0.0",
  "uptime": 3600,
  "checks": {
    "overall": "healthy",
    "database": {"status": "healthy", "message": "ETS tables available"},
    "websocket_pool": {"status": "healthy", "message": "WebSocket pool available"},
    "rate_limiter": {"status": "healthy", "message": "Rate limiter functional"},
    "configuration": {"status": "healthy", "message": "Gateway configuration valid"}
  }
}
```

## CORS Configuration

ExGateway handles CORS through the backend services it proxies to. However, you can configure CORS at the gateway level for additional control.

### Backend Service CORS (Recommended)

The recommended approach is to configure CORS in your backend services:

```elixir
# In your backend Phoenix application
config :cors_plug,
  origin: ["https://yourdomain.com", "https://app.yourdomain.com"],
  max_age: 86400,
  methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
```

### Gateway-Level CORS (Advanced)

For gateway-level CORS control, add a CORS plug to your pipeline:

1. **Add cors_plug dependency:**
   ```elixir
   # mix.exs
   defp deps do
     [
       {:cors_plug, "~> 3.0"}
     ]
   end
   ```

2. **Configure CORS plug:**
   ```elixir
   # lib/elixir_gateway_web/router.ex
   pipeline :cors do
     plug CORSPlug,
       origin: [
         "https://yourdomain.com",
         "https://app.yourdomain.com",
         ~r/https:\/\/.*\.yourdomain\.com$/
       ],
       max_age: 86400,
       methods: ["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD"],
       headers: [
         "Authorization", "Content-Type", "Accept", "Origin",
         "User-Agent", "X-Requested-With", "X-CSRF-Token", "X-User-ID"
       ]
   end
   ```

3. **Apply CORS to gateway pipeline:**
   ```elixir
   pipeline :gateway do
     plug :cors  # Add this line
     plug ElixirGatewayWeb.Plugs.RateLimiter
     plug ElixirGatewayWeb.Plugs.WebSocketUpgradePlug
     plug ElixirGatewayWeb.Plugs.DomainRouter
     plug ElixirGatewayWeb.Plugs.RequestForwarder
   end
   ```

### CORS Environment Variables

For dynamic CORS configuration:

```bash
export CORS_ORIGINS="https://app1.com,https://app2.com"
export CORS_MAX_AGE="3600"
export CORS_METHODS="GET,POST,PUT,DELETE,OPTIONS"
```

## Troubleshooting

### Common Issues

1. **Port conflicts**: Ensure ports 4000 and 4001 are available
2. **SSL certificate issues**: Check certificate storage directory permissions
3. **Rate limiting**: Verify ETS tables are created properly
4. **WebSocket connections**: Check connection pool configuration

### SSL Certificate Management

#### Reverting to Certbot (Let's Encrypt)

If you encounter SSL certificate issues with the default setup, you can revert to using certbot for Let's Encrypt certificate management:

**Prerequisites**: Install certbot on your system:
```bash
# Install certbot using the Makefile
make install-certbot

# Or install manually (visit https://certbot.eff.org/instructions for your OS)
```

**Configuration**: Update your endpoint configuration to use SiteEncrypt with Let's Encrypt:

1. **Update config/prod.exs**:
```elixir
# Configure the endpoint for HTTPS with Let's Encrypt
config :elixirgateway, ElixirGatewayWeb.Endpoint,
  https: [
    port: 4001,
    ip: {0, 0, 0, 0},
    cipher_suite: :strong,
    # SiteEncrypt will automatically provide these
    keyfile: {SiteEncrypt, {:pem_encoder, :key}},
    certfile: {SiteEncrypt, {:pem_encoder, :cert}}
  ],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true,
  check_origin: false

# SiteEncrypt configuration
config :site_encrypt, ElixirGateway.SiteEncrypt,
  endpoint: ElixirGatewayWeb.Endpoint
```

2. **Set required environment variables**:
```bash
export LETSENCRYPT_DOMAINS="api.yourdomain.com,service1.yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"
export LETSENCRYPT_STAGING="true"  # Use staging for testing
```

3. **See complete setup**: Refer to [LETSENCRYPT_SETUP.md](LETSENCRYPT_SETUP.md) for detailed Let's Encrypt configuration.

### Debug Mode

Enable debug logging for troubleshooting:

```bash
export LOG_LEVEL=debug
mix phx.server
```

### Health Check Debugging

Check specific health endpoints:

```bash
# General health
curl http://localhost:4000/health

# Readiness probe
curl http://localhost:4000/health/ready

# Liveness probe
curl http://localhost:4000/health/live
```