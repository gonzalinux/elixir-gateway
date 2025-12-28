# Distributed Active-Active Failover for ElixirGateway

## Overview

Enable two ElixirGateway instances (e.g., home + cloud) to operate as a single logical gateway with automatic DNS failover. **Opt-in feature, disabled by default.**

## User Experience

```elixir
# config/runtime.exs — Only needed if user enables clustering
config :elixirgateway, :cluster,
  enabled: true,  # Default: false
  secret: System.get_env("CLUSTER_SECRET"),
  node_name: System.get_env("NODE_NAME"),
  listen_port: 9100,
  peers: ["gateway-b.example.com:9100"],
  dns_failover: [
    enabled: true,
    provider: :namecheap_ddns,
    public_ip_method: :auto,
    domains: [
      %{host: "@", domain: "example.com", password: System.get_env("DDNS_PASS_EXAMPLE_COM")},
      %{host: "@", domain: "another.org", password: System.get_env("DDNS_PASS_ANOTHER")}
    ]
  ]
```

Secret generation:
```bash
mix elixir_gateway.gen.cluster_secret
# or
openssl rand -hex 32
```

## Architecture

```
                    Namecheap DNS
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
   ┌──────────┐   Dist.. Erlang (TLS)   ┌──────────┐
   │Gateway A │◄──────────────────►│Gateway B │
   │ Primary  │   Shared Secret    │Secondary │
   └────┬─────┘                    └────┬─────┘
        ▼                               ▼
    Backend A                       Backend B
```

## Certificate Management

When running a distributed cluster with the same domain on both nodes, only the **primary** node should generate Let's Encrypt certificates. The **secondary** node receives certificates from the primary via encrypted distributed Erlang RPC.

### Role Determination

**Auto-detection** (recommended):
- Empty `CLUSTER_PEERS` → Primary (generates certificates)
- Non-empty `CLUSTER_PEERS` → Secondary (receives certificates)

**Explicit override** (optional):
```bash
IS_PRIMARY="true"   # Forces node to be primary
IS_PRIMARY="false"  # Forces node to be secondary
```

### Certificate Sync Flow

```
Primary (Cloud)                Secondary (Home)
      │                              │
      │ 1. SiteEncrypt generates     │
      │    Let's Encrypt cert        │
      │                              │
      │ 2. CertificateManager        │
      │    reads cert files          │
      │                              │
      │ 3. Computes SHA-256          │
      │    checksum                  │
      │                              │
      │ 4. Distributed Erlang RPC ──►│ 5. Receives bundle
      │                              │
      │                              │ 6. Validates checksum
      │                              │
      │                              │ 7. Writes to disk
      │                              │    (0o600 permissions)
      │                              │
      │                              │ 8. Reloads SSL cache
      │                              │
      │ 9. ACK ◄────────────────────│
```

### Configuration

Certificate sync is **enabled by default** when clustering is enabled:

```elixir
config :elixirgateway, :cluster,
  enabled: true,
  cert_sync: [
    enabled: true,        # Default: true
    retry_delay: 5_000,   # Retry delay for failed syncs (ms)
    max_retries: 3,       # Max sync retry attempts
    rpc_timeout: 30_000   # RPC call timeout (ms)
  ]
```

### Primary Node Setup (Cloud)

```bash
# .env
CLUSTER_ENABLED=true
CLUSTER_SECRET=<shared-secret>
NODE_NAME=gateway-cloud
CLUSTER_PEERS=                    # Empty = auto-detected as primary

# Let's Encrypt configuration (primary generates certs)
LETSENCRYPT_DOMAINS=example.com,api.example.com
LETSENCRYPT_EMAIL=admin@example.com
SITE_ENCRYPT_DB=/etc/elixirgateway/certs
```

### Secondary Node Setup (Home)

```bash
# .env
CLUSTER_ENABLED=true
CLUSTER_SECRET=<same-shared-secret>
NODE_NAME=gateway-home
CLUSTER_PEERS=gateway-cloud@gateway-cloud.example.com:9100  # Non-empty = auto-detected as secondary

# Let's Encrypt NOT configured (receives from primary)
SITE_ENCRYPT_DB=/etc/elixirgateway/certs
```

### Benefits

- **No duplicate ACME challenges**: Only primary contacts Let's Encrypt
- **No rate limits**: Avoid hitting Let's Encrypt's rate limits
- **Seamless failover**: Secondary already has valid certificates
- **Automatic sync**: Happens automatically on cert generation/renewal
- **Secure transport**: Certificates transmitted over encrypted distributed Erlang connection
- **Integrity validation**: SHA-256 checksums prevent corruption

## Dependencies

```elixir
# mix.exs
{:req, "~> 0.4"}        # HTTP client for DNS API
```

## New Modules

| Module | Purpose |
|--------|---------|
| `ElixirGateway.Cluster.Supervisor` | Top-level supervisor; no-op if `enabled: false` |
| `ElixirGateway.Cluster.Manager` | Distributed Erlang setup, peer connection, health heartbeats |
| `ElixirGateway.Cluster.ConnectionRegistry` | Local ETS-based sticky sessions with TTL: `{client_ip, session_id}` → `backend_node` |
| `ElixirGateway.Cluster.CertificateManager` | SSL certificate synchronization from primary to secondary nodes |
| `ElixirGateway.Cluster.DNSFailover` | Monitors peer, triggers DDNS update on failure |
| `ElixirGateway.Cluster.DDNS.Namecheap` | DDNS client (same protocol as ddclient) |
| `ElixirGateway.Cluster.Secret` | Optional auto-generation if secret file missing |
| `Mix.Tasks.ElixirGateway.Gen.ClusterSecret` | Mix task for secret generation |

## Modifications to Existing Code

### `application.ex`

```elixir
def start(_type, _args) do
  children = [
    # ... existing children ...
    {ElixirGateway.Cluster.Supervisor, []}  # No-op if disabled
  ]
end
```

### `WebSocketUpgradePlug` / `RequestForwarder`

Add affinity check before processing:

```elixir
def call(conn, opts) do
  case ElixirGateway.Cluster.ConnectionRegistry.get_node(conn) do
    :local -> process_locally(conn, opts)
    {:remote, node} -> forward_to_node(conn, node)
    :not_clustered -> process_locally(conn, opts)  # Clustering disabled
  end
end
```

## Key Behaviors

| Scenario | Behavior |
|----------|----------|
| Clustering disabled | Zero overhead, current behavior unchanged |
| Both nodes healthy | First to claim request processes it, affinity stored |
| Existing connection | Always routes to same node (sticky) |
| Node fails | Surviving node updates DNS within ~5-10s, absorbs traffic |
| Node recovers | Rejoins cluster, new connections can route to it |

## Configuration Schema

```elixir
# Default (clustering off)
config :elixirgateway, :cluster, enabled: false

# Full options
config :elixirgateway, :cluster,
  enabled: false,                    # Opt-in
  secret: nil,                       # Required if enabled
  node_name: nil,                    # Required if enabled
  listen_port: 9100,
  peers: [],                         # Required if enabled
  heartbeat_interval: 1_000,
  failover_timeout: 5_000,
  dns_failover: [
    enabled: false,
    provider: :namecheap_ddns,       # Uses standard DDNS protocol (like ddclient)
    public_ip_method: :auto,         # :auto uses ipify.org, or {:static, "1.2.3.4"}
    domains: [
      # Each domain has its own DDNS password (from Namecheap dashboard)
      %{
        host: "@",                   # @ for root, or subdomain like "api"
        domain: "example.com",
        password: System.get_env("DDNS_PASS_EXAMPLE_COM")
      },
      %{
        host: "api",
        domain: "example.com",
        password: System.get_env("DDNS_PASS_EXAMPLE_COM")
      },
      %{
        host: "@",
        domain: "anotherdomain.org",
        password: System.get_env("DDNS_PASS_ANOTHER")
      }
    ]
  ]
```

## DDNS Implementation

Uses Namecheap's standard Dynamic DNS protocol (same as ddclient):

```elixir
defmodule ElixirGateway.Cluster.DDNS.Namecheap do
  @moduledoc """
  Namecheap DDNS client. Same protocol as ddclient.
  No API key needed — just the DDNS password from Namecheap dashboard.
  """
  
  @ddns_url "https://dynamicdns.park-your-domain.com/update"

  def update_all(domains, ip) do
    Enum.map(domains, fn %{host: host, domain: domain, password: pass} ->
      result = update(host, domain, pass, ip)
      Logger.info("DDNS update #{host}.#{domain} -> #{ip}: #{inspect(result)}")
      {domain, host, result}
    end)
  end

  def update(host, domain, password, ip) do
    url = "#{@ddns_url}?host=#{host}&domain=#{domain}&password=#{password}&ip=#{ip}"
    
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        if String.contains?(body, "<ErrCount>0</ErrCount>"), do: :ok, else: {:error, body}
      error -> 
        {:error, error}
    end
  end

  def get_public_ip do
    case Req.get("https://api.ipify.org") do
      {:ok, %{body: ip}} -> {:ok, String.trim(ip)}
      error -> error
    end
  end
end
```

## Implementation Order

1. `Cluster.Supervisor` — Conditional startup based on config
2. `Cluster.Manager` — Distributed Erlang integration, peer health
3. `Cluster.ConnectionRegistry` — Local ETS-based session registry with TTL
4. Plug modifications — Affinity checks
5. `Cluster.DNSFailover` + `Cluster.DDNS.Namecheap` — DDNS integration
6. Mix task — Secret generator
7. Documentation — Setup guide, docker-compose examples

## Testing Strategy

- **Unit tests**: Test session persistence, TTL cleanup, and routing logic
- **Integration**: Two-node docker-compose with simulated failures
- **Existing tests**: Must pass with `enabled: false` (default)

## Docker Deployment Example

```yaml
# docker-compose.yml (per site)
services:
  gateway:
    image: elixir-gateway:latest
    environment:
      - CLUSTER_SECRET=same-secret-on-both-nodes
      - NODE_NAME=gateway-a
      - CLUSTER_PEERS=gateway-b@gateway-b.example.com:9100
      # DDNS passwords from Namecheap dashboard (one per domain)
      - DDNS_PASS_EXAMPLE_COM=ddns-password-for-example
      - DDNS_PASS_ANOTHER=ddns-password-for-another
    ports:
      - "80:4000"
      - "443:4001"
      - "9100:9100"  # Cluster communication
```

## Open Questions

1. Support additional DDNS providers (Cloudflare, DuckDNS, No-IP) now or later?
2. Web UI for cluster status in LiveDashboard?
3. Graceful handoff (drain connections) vs instant failover?
