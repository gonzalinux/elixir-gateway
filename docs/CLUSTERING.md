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

```bash
# .env file
CLUSTER_ENABLED=true
CLUSTER_SECRET=<your-secret>
NODE_NAME=gateway-a
CLUSTER_PEERS=other-node.example.com:9100
DNS_FAILOVER_ENABLED=true
DDNS_DOMAINS=@:example.com:your-ddns-password
```

This is automatically parsed by `config/runtime.exs` into the cluster configuration.

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
      CLUSTER_ENABLED: "true"
      CLUSTER_SECRET: "your-secret"
      NODE_NAME: "gateway-a"
      CLUSTER_PEERS: "gateway-b@gateway-b.example.com:9100"
      DNS_FAILOVER_ENABLED: "true"
      DDNS_DOMAINS: "@:example.com:your-ddns-password"
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
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=<64-char-hex>
NODE_NAME=gateway-home
CLUSTER_PEERS=gateway-cloud@cloud.example.com:9100
DNS_FAILOVER_ENABLED=true
DDNS_DOMAINS=@:example.com:your-ddns-password
# PUBLIC_IP_STATIC not set - auto-detect changing IP
```

**Cloud Server (Secondary)** - Static IP, receives connections:
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=<same-secret>
NODE_NAME=gateway-cloud
CLUSTER_PEERS=  # Empty - just accepts connections
DNS_FAILOVER_ENABLED=false
# NODE_IP can be set to specify exact private IP if needed
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
4. Add to `DDNS_DOMAINS` environment variable (format: `host:domain:password`)

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

## Active-Active Load Distribution

**Feature Status:** Optional, requires explicit configuration

ElixirGateway supports active-active load distribution where the primary (home) server receives all DNS traffic and intelligently distributes load across all connected nodes based on configured weights.

### Architecture

```
DNS → Home Server (Primary - 100% traffic)
        ├─→ Home Backend (70% - weighted)
        ├─→ Cloud1 Backend (30% - RPC forward)
        └─→ Cloud2 Backend (15% - RPC forward)
```

**Key Features:**
- Weight-based proportional distribution
- Session affinity preservation across requests
- Traffic threshold (routes locally when below 20 req/min)
- Automatic fallback if remote node fails
- Dynamic weight recalculation on node connect/disconnect
- Zero overhead when disabled

### How It Works

1. **DNS Resolution**: All traffic points to primary (home) server
2. **Request Routing**:
   - **Below threshold** (<20 req/min): All traffic stays local (no RPC overhead)
   - **Above threshold**: New sessions distributed proportionally via RPC
   - **Existing sessions**: Always routed to original node (affinity preserved)
3. **RPC Forwarding**: Primary forwards requests to secondary nodes via Erlang RPC
4. **Failure Handling**: If secondary down, automatically falls back to local processing

### Weight-Based Distribution

Each node is assigned a **capacity weight** (points). Traffic is distributed proportionally:

**Example 1: Home Only**
- Primary (home): 70 points
- **Distribution**: Home = 100%

**Example 2: Home + 1 Cloud**
- Primary (home): 70 points
- Secondary (cloud1): 30 points
- Total: 100 points
- **Distribution**: Home = 70%, Cloud1 = 30%

**Example 3: Home + 2 Clouds**
- Primary (home): 70 points
- Secondary (cloud1): 30 points
- Secondary (cloud2): 15 points
- Total: 115 points
- **Distribution**: Home = 60.9%, Cloud1 = 26.1%, Cloud2 = 13.0%

### Configuration

#### Primary Server (Home) - Receives DNS Traffic

```bash
# Enable load distribution
LOAD_DISTRIBUTION_ENABLED=true

# This node's capacity weight (higher = more traffic)
NODE_WEIGHT=70

# Minimum requests per minute before distribution kicks in (default: 20)
MIN_REQ_THRESHOLD=20

# Cluster configuration (required)
CLUSTER_ENABLED=true
CLUSTER_SECRET=<64-char-hex>
NODE_NAME=gateway-home
CLUSTER_PEERS=cloud.example.com:9100
```

#### Secondary Servers (Cloud) - Share Load

```bash
# Enable load distribution (nodes auto-share weights via RPC)
LOAD_DISTRIBUTION_ENABLED=true

# This node's capacity weight (adjust based on server capacity)
NODE_WEIGHT=30

# Same threshold as primary
MIN_REQ_THRESHOLD=20

# Cluster configuration (required)
CLUSTER_ENABLED=true
CLUSTER_SECRET=<same-secret>
NODE_NAME=gateway-cloud1
CLUSTER_PEERS=  # Empty - accepts connections
IS_PRIMARY=false
```

**How It Works:**
- Each node declares its own `NODE_WEIGHT` based on its capacity
- When nodes connect, they automatically share weights via RPC
- The primary (DNS target) calculates traffic distribution dynamically
- No centralized weight configuration needed

### Complete Example

**Home Server (Primary):**
```bash
# Cluster setup
CLUSTER_ENABLED=true
CLUSTER_SECRET=abc123...
NODE_NAME=gateway-home
CLUSTER_PEERS=cloud1.example.com:9100,cloud2.example.com:9100
DNS_FAILOVER_ENABLED=true
DDNS_DOMAINS=@:example.com:password

# Load distribution
LOAD_DISTRIBUTION_ENABLED=true
NODE_WEIGHT=70
MIN_REQ_THRESHOLD=20
```

**Cloud Server 1:**
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=abc123...
NODE_NAME=gateway-cloud1
CLUSTER_PEERS=  # Empty
IS_PRIMARY=false

# Load distribution with medium capacity
LOAD_DISTRIBUTION_ENABLED=true
NODE_WEIGHT=30
MIN_REQ_THRESHOLD=20
```

**Cloud Server 2:**
```bash
CLUSTER_ENABLED=true
CLUSTER_SECRET=abc123...
NODE_NAME=gateway-cloud2
CLUSTER_PEERS=  # Empty
IS_PRIMARY=false

# Load distribution with lower capacity
LOAD_DISTRIBUTION_ENABLED=true
NODE_WEIGHT=15
MIN_REQ_THRESHOLD=20
```

### Monitoring & Metrics

Load distribution exposes several Prometheus metrics:

#### Request Distribution
```prometheus
# Requests routed to each node
elixirgateway_load_distribution_request_total{target_node="gateway-home@..."}

# RPC forwarding latency
elixirgateway_rpc_forward_duration_milliseconds{destination_node="gateway-cloud1@...",status="ok"}
```

#### Node Weights
```prometheus
# Weight per node
elixirgateway_load_distribution_node_weight{node_name="gateway-home@..."}

# Total active weight
elixirgateway_load_distribution_total_weight

# Feature status
elixirgateway_load_distribution_enabled  # 1=enabled, 0=disabled

# Traffic threshold status
elixirgateway_load_distribution_below_threshold  # 1=below, 0=above
```

### Verification

After configuration, verify load distribution:

```bash
# 1. Check metrics endpoint
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep load_distribution

# Expected output with 2 secondaries (70+30+15=115):
# elixirgateway_load_distribution_total_weight 115
# elixirgateway_load_distribution_node_weight{node_name="gateway-home@..."} 70
# elixirgateway_load_distribution_node_weight{node_name="gateway-cloud1@..."} 30
# elixirgateway_load_distribution_node_weight{node_name="gateway-cloud2@..."} 15
# elixirgateway_load_distribution_enabled 1

# 2. Generate load and check distribution
ab -n 1000 -c 10 https://yourdomain.com/api/health

# 3. Verify request counts (should match weight proportions)
curl -H "Authorization: Bearer $METRICS_TOKEN" https://yourdomain.com/metrics | grep load_distribution_request_total
```

### Performance Impact

**Latency:**
- Local requests: 0ms overhead (no change)
- Forwarded requests: +10-50ms (RPC + remote processing)
- Only affects traffic routed to secondary nodes
- Below threshold: Zero overhead (all local)

**Throughput:**
- Scales proportionally to total configured weights
- Example: 70 + 30 + 15 = 115 points = ~64% capacity increase
- Add more secondaries to further increase capacity

### Failure Scenarios

#### Secondary Node Fails
- RPC returns `:nodedown`
- Automatic fallback to local processing
- LoadDistributor excludes failed node from weight calculation
- Example: Home=70, Cloud1=30, Cloud2=15 → Cloud1 fails → Home=82.4%, Cloud2=17.6%
- No user impact (graceful degradation)

#### Primary Node Fails
- DNS failover switches to cloud IP
- Cloud processes 100% of traffic locally (no forwarding)
- Existing sessions lost (users reconnect)

#### Session Affinity Conflict
- Session registered on cloud, cloud is down
- Same as secondary failure - fallback to local
- May cause temporary backend inconsistency (backend should handle eventual consistency)

### Traffic Threshold Behavior

When traffic is **below** the minimum threshold (default: 20 requests/minute):
- All traffic stays on primary (home) server
- Secondary nodes sit idle but ready
- Prevents RPC overhead for low traffic periods
- Automatically switches to distributed mode when traffic increases

When traffic **exceeds** the threshold:
- New sessions distributed via weighted random selection
- Existing sessions maintain affinity to original node
- Proportional distribution based on configured weights

### Dynamic Node Management

**Adding a New Secondary:**
1. Configure new node with clustering enabled and set `NODE_WEIGHT`
2. Start the new node (connects to cluster automatically)
3. Node shares its weight via RPC when connecting
4. LoadDistributor immediately includes it in traffic distribution
5. No configuration changes needed on other nodes

**Removing a Secondary:**
1. Stop the secondary node
2. LoadDistributor detects `:nodedown` event automatically
3. Removes node from weight calculation immediately
4. Traffic redistributes to remaining nodes
5. No manual intervention required

### Troubleshooting

**Issue: All traffic goes to primary even when above threshold**
- Check `LOAD_DISTRIBUTION_ENABLED=true` on primary
- Verify secondary nodes are connected: Check cluster health metrics
- Check logs for "Selected node via weighted distribution"

**Issue: High RPC latency**
- Check network latency between primary and secondary
- Verify secondary nodes have sufficient resources
- Monitor `elixirgateway_rpc_forward_duration_milliseconds` metric
- Consider adjusting weights to reduce traffic to slow nodes

**Issue: Sessions not maintaining affinity**
- Verify `ConnectionRegistry` is running (check cluster metrics)
- Check session identification (X-Session-ID header or cookies)
- Monitor `elixirgateway_session_registry_active_sessions` metric

**Issue: Secondary node showing in metrics but not receiving traffic**
- Verify node is actually connected to cluster
- Check `elixirgateway_load_distribution_node_weight` metric
- Ensure traffic is above threshold (check `elixirgateway_load_distribution_below_threshold`)

### Best Practices

1. **Weight Assignment**: Assign weights proportional to actual hardware capacity
2. **Threshold Configuration**: Adjust `MIN_REQ_THRESHOLD` based on your traffic patterns
3. **Monitoring**: Set up alerts on RPC latency and node availability
4. **Session Affinity**: Use consistent session identifiers (cookies or X-Session-ID)
5. **Gradual Rollout**: Start with one secondary, verify behavior, then add more
6. **Capacity Planning**: Monitor weight distribution and adjust as needed
7. **Testing**: Test failover scenarios in staging before production
