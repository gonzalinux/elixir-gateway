# Clustering Guide

ElixirGateway supports distributed clustering for high availability. Multiple gateway instances can work together with automatic failover.

**Opt-in feature - disabled by default.**

## Two Clustering Approaches

ElixirGateway supports two different clustering systems:

### Native Erlang Clustering (CLUSTER_ENABLED) - Recommended for Most Use Cases

**Use when:** Cloud + home deployments, different networks, shared domains
**Technology:** Erlang distribution with TLS 1.2 PSK authentication
**Benefits:** Works across NAT/firewalls, automatic certificate sync, DNS failover, simpler architecture

```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=<64-char-hex>
NODE_NAME=gateway-a
CLUSTER_PEERS=gateway-b@gateway-b.example.com:9100
```

**Security:** Uses Pre-Shared Key (PSK) with Diffie-Hellman for forward secrecy (PSK-DHE cipher suites).

### DNS Clustering (DNS_CLUSTER_QUERY) - For Kubernetes/Swarm Only

**Use when:** All nodes in same network (Kubernetes, Docker Swarm)
**Technology:** Erlang distribution with DNS discovery
**Limitations:** No encryption, doesn't work across NAT, no certificate sync

```bash
DNS_CLUSTER_QUERY=elixirgateway.default.svc.cluster.local
```

**Important:** Don't use both at the same time. For cloud + home with shared domains, use native Erlang clustering.

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
      CLUSTER_PEERS: "gateway-b@gateway-b.example.com:9100"
      DDNS_PASS: "your-ddns-password"
    ports:
      - "80:4000"
      - "443:4001"
      - "9100:9100"
```

## How It Works

- **Node Naming**: Nodes use `name@ip` format (e.g., `gateway-a@192.168.1.10`)
- **IP Detection**: Local IP auto-detected or configurable via `node_ip`
- **TLS Encryption**: TLS 1.2 with PSK-DHE cipher suites (forward secrecy)
- **Authentication**: Pre-Shared Key (PSK) from `CLUSTER_SECRET` environment variable
- **Health Monitoring**: Nodes monitor each other via `:net_kernel.monitor_nodes/1`
- **Sticky Sessions**: Connections stay on the same node
- **Automatic Failover**: ~5-10 seconds when peer fails
- **Auto Recovery**: Failed nodes rejoin automatically
- **Automatic Reconnection**: Disconnected peers reconnect every 5 seconds
- **Zero Overhead**: No performance impact when disabled

## Asymmetric Setup (Cloud + Home Server)

For deployments with one static IP (cloud) and one dynamic IP (home):

### Recommended: Home Server as Primary

**Home Server (Primary)** - Dynamic IP, manages DNS, initiates connections:
```elixir
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: "gateway-home",
  node_ip: nil,  # Auto-detect (optional, can be omitted)
  listen_port: 9100,
  peers: ["gateway-cloud@cloud.example.com:9100"],  # Knows cloud's static address
  dns_failover: [
    enabled: true,  # Primary manages DNS failover
    public_ip_method: :auto,  # Auto-detect changing IP
    domains: [
      %{host: "@", domain: "example.com", password: System.get_env("DDNS_PASS")}
    ]
  ]
```

**Cloud Server (Secondary)** - Static IP, receives connections:
```elixir
config :elixirgateway, :cluster,
  enabled: true,
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: "gateway-cloud",
  node_ip: System.get_env("CLOUD_PRIVATE_IP"),  # Optional: specify exact IP
  listen_port: 9100,
  peers: [],  # Empty - just accepts connections
  dns_failover: [
    enabled: false  # Secondary doesn't manage DNS
  ]
```

**Environment Variables (Alternative):**

Home Server:
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=<64-char-hex>
NODE_NAME=gateway-home
CLUSTER_PEERS=gateway-cloud@cloud.example.com:9100
DNS_FAILOVER_ENABLED=true
DDNS_DOMAINS=@:example.com:password
```

Cloud Server:
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=<same-secret>
NODE_NAME=gateway-cloud
CLUSTER_PEERS=  # Empty
DNS_FAILOVER_ENABLED=false
```

**Role Detection:**
- Explicit: Use `IS_PRIMARY=true` (home) or `IS_PRIMARY=false` (cloud)
- Auto-detect: DNS failover enabled → Primary role (home manages DNS when cloud fails)

**Why this works:**
- Home knows cloud's stable address and initiates connection
- Erlang distribution creates bidirectional connection (both see each other)
- When home IP changes, connection breaks → home reconnects automatically
- Cloud doesn't need to know home's changing IP (it changes constantly)
- Home manages DNS updates (primary role)
- Cloud just handles traffic (secondary role)
- TLS encryption protects all cluster communication

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
# "Started distributed node: gateway-a@192.168.1.10 (TLS 1.2 PSK-DHE Enabled)"
```

## Technical Details

### TLS Configuration

The cluster uses native Erlang distribution with TLS configured via `priv/ssl_dist.conf`:

- **Protocol**: TLS 1.2 (Erlang doesn't support external PSK for TLS 1.3)
- **Cipher Suites**: DHE-PSK with AES-GCM (forward secrecy + authenticated encryption)
- **Authentication**: Pre-Shared Key retrieved from `CLUSTER_SECRET` environment variable
- **Timeouts**: 5-second send timeout for fast failure detection

### Security Considerations

- **Secret Length**: Minimum 32 bytes (64 hex characters) required
- **Secret Storage**: Should be stored securely and never committed to version control
- **Forward Secrecy**: DHE-PSK ciphersuites provide forward secrecy
- **No Certificates**: PSK authentication eliminates certificate management overhead
