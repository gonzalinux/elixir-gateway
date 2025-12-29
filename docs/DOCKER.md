# ElixirGateway Docker Deployment Guide

This guide explains how to build, configure, and deploy ElixirGateway using Docker containers.

## Quick Start

### Build the Docker Image

```bash
# Build the production image
docker build -t elixirgateway:latest .

# Build with a specific tag
docker build -t elixirgateway:1.0.0 .
```

### Run the Container

```bash
# Basic run (development/testing)
docker run -p 4000:4000 -p 4001:4001 -p 4002:4002 elixirgateway:latest

# Production run with environment variables
docker run -d \
  --name elixirgateway \
  -p 4000:4000 \
  -p 4001:4001 \
  -p 4002:4002 \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST="api.yourdomain.com" \
  -e LETSENCRYPT_DOMAINS="api.yourdomain.com,app.yourdomain.com" \
  -e LETSENCRYPT_EMAIL="admin@yourdomain.com" \
  -v /etc/ssl/elixirgateway:/etc/elixirgateway/certs \
  elixirgateway:latest
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

# Optional
export HTTP_PORT="4000"
export HTTPS_PORT="4001"
export DNS_CLUSTER_QUERY="api.cluster.local"
```
