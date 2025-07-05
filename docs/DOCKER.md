# ExGateway Docker Deployment Guide

This guide explains how to build, configure, and deploy ExGateway using Docker containers.

## Quick Start

### Build the Docker Image

```bash
# Build the production image
docker build -t exgateway:latest .

# Build with a specific tag
docker build -t exgateway:1.0.0 .
```

### Run the Container

```bash
# Basic run (development/testing)
docker run -p 4000:4000 -p 4001:4001 exgateway:latest

# Production run with environment variables
docker run -d \
  --name exgateway \
  -p 4000:4000 \
  -p 4001:4001 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST="api.yourdomain.com" \
  -e LETSENCRYPT_DOMAINS="api.yourdomain.com,app.yourdomain.com" \
  -e LETSENCRYPT_EMAIL="admin@yourdomain.com" \
  -v /etc/ssl/exgateway:/etc/elixirgateway/certs \
  exgateway:latest
```

## Docker Image Details

### Multi-Stage Build

The Dockerfile uses a multi-stage build process for optimal image size:

1. **Builder Stage**: Uses Elixir/Alpine image to compile and create release
2. **Runtime Stage**: Uses minimal Alpine image with only runtime dependencies

### Image Specifications

- **Base Image**: Alpine Linux 3.18.4
- **Runtime**: Erlang/OTP with Elixir release
- **Size**: ~50MB (compared to ~200MB+ with full Elixir image)
- **User**: Runs as non-root user `gateway` (UID: 1000)
- **Ports**: 4000 (HTTP), 4001 (HTTPS)

### Built-in Health Check

The image includes a health check that runs every 30 seconds:
```bash
curl -f http://localhost:4000/health || exit 1
```

## Configuration

### Environment Variables

All environment variables from the main setup guide are supported:

```bash
# Required for production
export SECRET_KEY_BASE="$(openssl rand -base64 64)"
export PHX_HOST="api.yourdomain.com"

# SSL Configuration
export LETSENCRYPT_DOMAINS="api.yourdomain.com,app.yourdomain.com"
export LETSENCRYPT_EMAIL="admin@yourdomain.com"
export CERT_DB_FOLDER="/etc/elixirgateway/certs"

# Optional
export PORT="4000"
export PHX_SERVER="true"
export DNS_CLUSTER_QUERY="api.cluster.local"
```

### Gateway Services Configuration

Create a configuration file and mount it into the container:

```elixir
# config/docker.exs
import Config

config :elixirgateway, :gateway,
  services: %{
    "api.yourdomain.com" => "http://backend-api:8080",
    "app.yourdomain.com" => "http://backend-app:3000",
    "ws.yourdomain.com" => "ws://websocket-service:4000"
  },
  rate_limit: [
    user_requests_per_minute: 100,
    ip_requests_per_minute: 500,
    cleanup_interval: :timer.minutes(1)
  ]

config :elixirgateway, :websocket,
  connection_pool: [
    size: 10,
    max_idle_time: 300_000
  ],
  upgrade_timeout: 30_000,
  reconnect_max_attempts: 3,
  reconnect_base_delay: 1_000,
  reconnect_max_delay: 10_000,
  message_queue_max_size: 100,
  ping_interval: 30_000
```

Mount the configuration:
```bash
docker run -v ./config/docker.exs:/app/config/runtime.local.exs exgateway:latest
```

## Docker Compose

### Basic Setup

```yaml
# docker-compose.yml
version: '3.8'

services:
  exgateway:
    build: .
    ports:
      - "4000:4000"
      - "4001:4001"
    environment:
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=${PHX_HOST}
      - LETSENCRYPT_DOMAINS=${LETSENCRYPT_DOMAINS}
      - LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
    volumes:
      - ssl_certs:/etc/elixirgateway/certs
      - ./config/docker.exs:/app/config/runtime.local.exs:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  ssl_certs:
```

### With Backend Services

```yaml
# docker-compose.yml
version: '3.8'

services:
  exgateway:
    build: .
    ports:
      - "80:4000"
      - "443:4001"
    environment:
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=api.yourdomain.com
      - LETSENCRYPT_DOMAINS=api.yourdomain.com,app.yourdomain.com
      - LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
    volumes:
      - ssl_certs:/etc/elixirgateway/certs
      - ./config/docker.exs:/app/config/runtime.local.exs:ro
    depends_on:
      - backend-api
      - backend-app
    restart: unless-stopped
    networks:
      - gateway-network

  backend-api:
    image: your-api-service:latest
    expose:
      - "8080"
    networks:
      - gateway-network

  backend-app:
    image: your-app-service:latest
    expose:
      - "3000"
    networks:
      - gateway-network

volumes:
  ssl_certs:

networks:
  gateway-network:
    driver: bridge
```

### Environment File

Create a `.env` file for Docker Compose:

```bash
# .env
SECRET_KEY_BASE=your-secret-key-base-here
PHX_HOST=api.yourdomain.com
LETSENCRYPT_DOMAINS=api.yourdomain.com,app.yourdomain.com
LETSENCRYPT_EMAIL=admin@yourdomain.com
```

## Kubernetes Deployment

### Deployment Manifest

```yaml
# k8s/deployment.yml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exgateway
  labels:
    app: exgateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app: exgateway
  template:
    metadata:
      labels:
        app: exgateway
    spec:
      containers:
      - name: exgateway
        image: exgateway:latest
        ports:
        - containerPort: 4000
          name: http
        - containerPort: 4001
          name: https
        env:
        - name: SECRET_KEY_BASE
          valueFrom:
            secretKeyRef:
              name: exgateway-secrets
              key: secret-key-base
        - name: PHX_HOST
          value: "api.yourdomain.com"
        - name: PHX_SERVER
          value: "true"
        - name: LETSENCRYPT_DOMAINS
          value: "api.yourdomain.com,app.yourdomain.com"
        - name: LETSENCRYPT_EMAIL
          valueFrom:
            secretKeyRef:
              name: exgateway-secrets
              key: letsencrypt-email
        volumeMounts:
        - name: ssl-certs
          mountPath: /etc/elixirgateway/certs
        - name: config
          mountPath: /app/config/runtime.local.exs
          subPath: runtime.local.exs
        livenessProbe:
          httpGet:
            path: /health/live
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: ssl-certs
        persistentVolumeClaim:
          claimName: exgateway-ssl-pvc
      - name: config
        configMap:
          name: exgateway-config
```

### Service Manifest

```yaml
# k8s/service.yml
apiVersion: v1
kind: Service
metadata:
  name: exgateway-service
spec:
  selector:
    app: exgateway
  ports:
  - name: http
    port: 80
    targetPort: 4000
  - name: https
    port: 443
    targetPort: 4001
  type: LoadBalancer
```

### ConfigMap for Gateway Configuration

```yaml
# k8s/configmap.yml
apiVersion: v1
kind: ConfigMap
metadata:
  name: exgateway-config
data:
  runtime.local.exs: |
    import Config
    
    config :elixirgateway, :gateway,
      services: %{
        "api.yourdomain.com" => "http://backend-api-service:8080",
        "app.yourdomain.com" => "http://backend-app-service:3000"
      },
      rate_limit: [
        user_requests_per_minute: 100,
        ip_requests_per_minute: 500,
        cleanup_interval: :timer.minutes(1)
      ]
```

### Secrets Manifest

```yaml
# k8s/secrets.yml
apiVersion: v1
kind: Secret
metadata:
  name: exgateway-secrets
type: Opaque
data:
  secret-key-base: <base64-encoded-secret>
  letsencrypt-email: <base64-encoded-email>
```

## Production Considerations

### Security

1. **Non-root user**: Container runs as `gateway` user (UID: 1000)
2. **Minimal image**: Alpine-based runtime image with only essential packages
3. **Secret management**: Use external secret management (Kubernetes secrets, Docker secrets)
4. **SSL certificates**: Mount persistent volume for certificate storage

### Performance

1. **Resource limits**: Set appropriate CPU and memory limits
2. **Connection pooling**: Configure WebSocket connection pool size
3. **Rate limiting**: Adjust rate limits based on expected traffic
4. **Health checks**: Configure appropriate timeouts and intervals

### Monitoring

1. **Health endpoints**: Use `/health`, `/health/ready`, `/health/live`
2. **Metrics**: Expose `/metrics` endpoint for Prometheus
3. **Logging**: Container logs to stdout/stderr for log aggregation
4. **Tracing**: Configure distributed tracing if needed

### Scaling

1. **Horizontal scaling**: Deploy multiple replicas
2. **Load balancing**: Use external load balancer or ingress
3. **Session affinity**: Not required (stateless gateway)
4. **Rolling updates**: Zero-downtime deployments

## Troubleshooting

### Common Issues

1. **Permission denied**: Ensure volumes have correct ownership
   ```bash
   sudo chown -R 1000:1000 /path/to/ssl/certs
   ```

2. **Health check failures**: Check if services are properly configured
   ```bash
   docker exec exgateway curl -f http://localhost:4000/health
   ```

3. **SSL certificate issues**: Verify certificate volume mount and permissions
   ```bash
   docker exec exgateway ls -la /etc/elixirgateway/certs
   ```

4. **Configuration errors**: Check mounted configuration file
   ```bash
   docker exec exgateway cat /app/config/runtime.local.exs
   ```

### Debug Mode

Run container with debug output:

```bash
docker run -e LOG_LEVEL=debug exgateway:latest
```

### Container Shell Access

Access container shell for debugging:

```bash
# Running container
docker exec -it exgateway /bin/sh

# One-time debugging
docker run -it --entrypoint /bin/sh exgateway:latest
```

### Build Arguments

Customize build with build arguments:

```bash
# Use different Elixir version
docker build --build-arg ELIXIR_VERSION=1.16 -t exgateway:latest .

# Use different base image
docker build --build-arg ALPINE_VERSION=3.19 -t exgateway:latest .
```

## Development

### Development Docker Setup

For development with hot reloading:

```dockerfile
# Dockerfile.dev
FROM hexpm/elixir:1.15.7-erlang-26.1.2-alpine-3.18.4

RUN apk add --no-cache build-base git inotify-tools

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

COPY . .

EXPOSE 4000 4001

CMD ["mix", "phx.server"]
```

```yaml
# docker-compose.dev.yml
version: '3.8'

services:
  exgateway-dev:
    build:
      context: .
      dockerfile: Dockerfile.dev
    ports:
      - "4000:4000"
      - "4001:4001"
    volumes:
      - .:/app
      - /app/_build
      - /app/deps
    environment:
      - MIX_ENV=dev
```

This setup provides a complete Docker deployment solution for ExGateway with production-ready configurations and comprehensive documentation.