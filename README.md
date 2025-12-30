# ElixirGateway
[![Elixir CI](https://github.com/gonzalinux/elixir-gateway/actions/workflows/elixir.yml/badge.svg)](https://github.com/gonzalinux/elixir-gateway/actions/workflows/elixir.yml)



A high-performance API Gateway built with Phoenix that provides domain-based routing, rate limiting, SSL/TLS support, WebSocket proxying, and comprehensive monitoring.

## Features

- **Domain-based routing**: Route requests to internal services based on domain
- **Rate limiting**: 100 requests per minute per user (configurable)
- **SSL/TLS support**: Automatic Let's Encrypt certificates or manual SSL configuration
- **WebSocket proxying**: Transparent WebSocket proxying with session preservation
- **Phoenix LiveView support**: Full support for LiveView applications with session continuity
- **Large file uploads**: Support for files up to 20MB with chunked reading
- **Prometheus metrics**: Complete observability with PromEx (path and host labels)
- **High availability clustering**: Distributed Erlang clustering with automatic failover
- **High performance**: Uses Finch HTTP client for optimal connection pooling

## Quick Start

1. **Setup project**:
   ```bash
   make setup
   ```

2. **Configure services** in `config/dev.exs`:
   ```elixir
   config :elixirgateway, :gateway,
     services: %{
       "api.yourdomain.com" => "http://192.168.1.10:8080",
       "app.yourdomain.com" => "https://192.168.1.11:4000"
     }
   ```

3. **Start the server**:
   ```bash
   make run
   ```

## Documentation

- [Setup Guide](docs/SETUP.md) - Complete configuration and deployment guide
- [Clustering Guide](docs/CLUSTERING.md) - High availability clustering with automatic failover
- [Let's Encrypt Setup](docs/LETSENCRYPT_SETUP.md) - Automatic SSL certificate management
- [WebSocket Proxy Architecture](docs/WebSocket_Proxy_Architecture.md) - WebSocket proxying details
- [Phoenix Deployment Guide](https://hexdocs.pm/phoenix/deployment.html) - Creating releases for production

## Monitoring

- **Prometheus metrics**: Available at `/metrics`
- **LiveDashboard**: Available at `/dev/dashboard` (development only)

## Architecture

```
Internet → Elixir-Gateway → Internal Services
    ↓
[Rate Limit] → [Domain Router] → [Request Forwarder]
    ↓                                ↓
[Metrics Collection]            [Finch HTTP Client]
```

Built with Phoenix v1.7.21 and Elixir ~> 1.16
