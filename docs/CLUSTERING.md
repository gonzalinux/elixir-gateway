# Clustering Guide

ElixirGateway supports distributed clustering for high availability. Multiple gateway instances can work together with automatic failover.

**Opt-in feature - disabled by default.**

## Architecture

```
   Gateway A ◄──────────────────► Gateway B
   (Primary)   Encrypted P2P      (Secondary)
       │                               │
       ▼                               ▼
   Backend A                       Backend B
```

When a node fails, the surviving node automatically updates DNS to take over traffic.

## Basic Setup

### 1. Generate Shared Secret

```bash
mix elixir_gateway.gen.cluster_secret
# or
openssl rand -hex 32
```

### 2. Configure Each Node

```elixir
# config/runtime.exs
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: System.get_env("NODE_NAME"),      # "gateway-a" or "gateway-b"
  node_ip: System.get_env("NODE_IP"),          # Optional, auto-detected if not set
  listen_port: 9100,
  peers: ["other-node.example.com:9100"]
```

**Note:** Node names use the format `name@ip`. The IP is auto-detected from network interfaces, but you can override it with `node_ip` config.

### 3. Enable DNS Failover (Optional)

Requires Namecheap DDNS enabled in your domain dashboard.

```elixir
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: System.get_env("NODE_NAME"),
  listen_port: 9100,
  peers: ["other-node.example.com:9100"],
  dns_failover: [
    enabled: true,
    provider: :namecheap_ddns,
    public_ip_method: :auto,  # or {:static, "1.2.3.4"}
    domains: [
      %{host: "@", domain: "example.com", password: System.get_env("DDNS_PASS")}
    ]
  ]
```

## Configuration Options

### Core Settings

- `enabled` - Enable clustering (default: `false`)
- `secret` - Shared secret for node authentication
- `node_name` - Unique name for this node
- `node_ip` - IP address for this node (optional, auto-detected if not provided)
- `listen_port` - Port for node communication (default: `9100`)
- `peers` - List of peer addresses `["host:port"]`

### DNS Failover

- `enabled` - Enable automatic DNS updates (default: `false`)
- `provider` - `:namecheap_ddns` (only supported provider)
- `public_ip_method` - `:auto` or `{:static, "ip"}`
- `domains` - List of domains to update on failover

### Public IP Methods

- `:auto` - Auto-detect using ipify.org
- `{:static, "203.0.113.10"}` - Use specific IP address

## Docker Example

```yaml
services:
  gateway:
    image: elixir-gateway:latest
    environment:
      CLUSTER_SECRET: "your-secret"
      NODE_NAME: "gateway-a"
      CLUSTER_PEERS: "gateway-b.example.com:9100"
      DDNS_PASS: "your-ddns-password"
    ports:
      - "80:4000"
      - "443:4001"
      - "9100:9100"
```

## How It Works

- **Node Naming**: Nodes use `name@ip` format (e.g., `gateway-a@192.168.1.10`)
- **IP Detection**: Local IP auto-detected or configurable via `node_ip`
- **Health Monitoring**: Nodes check each other every second
- **Sticky Sessions**: Connections stay on the same node
- **Automatic Failover**: ~5-10 seconds when peer fails
- **Auto Recovery**: Failed nodes rejoin automatically
- **Automatic Reconnection**: Disconnected peers reconnect every second
- **Zero Overhead**: No performance impact when disabled

## Asymmetric Setup (Cloud + Home Server)

For deployments with one static IP (cloud) and one dynamic IP (home):

**Cloud Node** (static IP, accepts connections):
```elixir
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: "gateway-cloud",
  node_ip: System.get_env("CLOUD_PRIVATE_IP"),  # Optional: specify exact IP
  listen_port: 9100,
  peers: [],  # Empty - accepts connections only
  dns_failover: [
    enabled: true,
    public_ip_method: {:static, System.get_env("CLOUD_PUBLIC_IP")},
    domains: [...]
  ]
```

**Home Node** (dynamic IP, initiates connections):
```elixir
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: "gateway-home",
  node_ip: nil,  # Auto-detect (optional, can be omitted)
  listen_port: 9100,
  peers: ["cloud.example.com:9100"],  # Connects to stable address
  dns_failover: [
    enabled: true,
    public_ip_method: :auto,  # Auto-detect changing IP
    domains: [...]
  ]
```

**Why this works:**
- Home knows cloud's stable address and initiates connection
- Partisan creates bidirectional connection (both see each other)
- When home IP changes, connection breaks → home reconnects automatically
- Cloud doesn't need to know home's changing IP
- DNS failover works on both nodes independently

## Monitoring

```elixir
# Check cluster health
ElixirGateway.Cluster.Manager.cluster_healthy?()

# Check DNS failover status
ElixirGateway.Cluster.DNSFailover.status()

# Manual failover trigger
ElixirGateway.Cluster.DNSFailover.trigger_failover()
```

## Namecheap DDNS Setup

1. Domain List → Manage → Advanced DNS
2. Enable "Dynamic DNS"
3. Copy DDNS password
4. Set as environment variable: `DDNS_PASS`

## Troubleshooting

- **Nodes not connecting**: Check port 9100 is open and secrets match
- **Wrong IP detected**: Set `node_ip` explicitly in config to override auto-detection
- **DNS not updating**: Verify DDNS password and Dynamic DNS is enabled
- **Performance impact**: Only ~1ms per request when enabled

### Checking Node Identity

To verify the node name being used:
```elixir
# In IEx or logs, look for:
# "Partisan 5.0.3 started as gateway-a@192.168.1.10 on port 9100"
```
