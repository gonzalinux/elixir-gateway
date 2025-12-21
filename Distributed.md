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
   ┌──────────┐   Partisan (TLS)   ┌──────────┐
   │Gateway A │◄──────────────────►│Gateway B │
   │ Primary  │   Shared Secret    │Secondary │
   └────┬─────┘                    └────┬─────┘
        ▼                               ▼
    Backend A                       Backend B
```

## Dependencies

```elixir
# mix.exs
{:partisan, "~> 5.0"},  # Encrypted node distribution
{:syn, "~> 3.3"},       # Distributed process registry
{:req, "~> 0.4"}        # HTTP client for DNS API
```

## New Modules

| Module | Purpose |
|--------|---------|
| `ElixirGateway.Cluster.Supervisor` | Top-level supervisor; no-op if `enabled: false` |
| `ElixirGateway.Cluster.Manager` | Partisan setup, peer connection, health heartbeats |
| `ElixirGateway.Cluster.ConnectionRegistry` | Distributed sticky sessions via Syn: `{client_ip, session_id}` → `node` |
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
2. `Cluster.Manager` — Partisan integration, peer health
3. `Cluster.ConnectionRegistry` — Syn-based distributed registry
4. Plug modifications — Affinity checks
5. `Cluster.DNSFailover` + `Cluster.DDNS.Namecheap` — DDNS integration
6. Mix task — Secret generator
7. Documentation — Setup guide, docker-compose examples

## Testing Strategy

- **Unit tests**: Mock Partisan/Syn for registry logic
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
      - CLUSTER_PEERS=gateway-b.example.com:9100
      # DDNS passwords from Namecheap dashboard (one per domain)
      - DDNS_PASS_EXAMPLE_COM=ddns-password-for-example
      - DDNS_PASS_ANOTHER=ddns-password-for-another
    ports:
      - "80:4000"
      - "443:4001"
      - "9100:9100"  # Partisan
```

## Open Questions

1. Support additional DDNS providers (Cloudflare, DuckDNS, No-IP) now or later?
2. Web UI for cluster status in LiveDashboard?
3. Graceful handoff (drain connections) vs instant failover?
