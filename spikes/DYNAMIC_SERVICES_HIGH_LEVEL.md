# Dynamic Service Registration — High Level Spec

## Purpose

Replace (or complement) the static host-to-target configuration with a system where
services register themselves with the gateway at runtime. This eliminates manual
config changes for deployments, enables zero-downtime version transitions, and
allows horizontal scaling of a service simply by running another instance.

## Goals

- Services declare their own existence; the gateway discovers them rather than
  being pre-configured with them.
- Multiple instances of the same service version are treated as a pool and receive
  traffic equally (horizontal scaling).
- Deploying a new version of a service produces a controlled, gradual traffic shift
  with automatic rollback on failure.
- The registry survives gateway restarts via disk persistence.
- The registration API is only reachable from internal network addresses.
- Cluster nodes each maintain their own registry; load distribution already handles
  skipping nodes that cannot route a given host.

## Features

### 1. Self-Registration
A service sends a single POST request to the gateway's internal API to announce
itself. The payload includes the host it handles, the target address (host:port),
its version identifier, and optionally a health check path and a transition
schedule for canary deployments.

If no transition is specified, the service is immediately added to the active pool
for its version.

### 2. Instance Pooling (same host, same version)
When multiple instances register with the same host and version, they form a pool.
Incoming requests are distributed randomly across all healthy instances in that
pool. This is the standard horizontal scaling model.

### 3. Gradual Version Transition (same host, different version)
When a new version registers for a host that already has an active version, the
gateway begins a phased traffic shift defined by the new version's transition
schedule.

Each phase specifies a traffic percentage and a duration. The phases are executed
sequentially. After all phases complete, the new version receives 100% of traffic
and the old version's entry is removed.

Example transition:
- Phase 1: 10% to new version for 1 minute
- Phase 2: 50% to new version for 5 minutes
- After phase 2: 100% to new version, old version removed

If no transition schedule is provided at registration, the switch is immediate
(equivalent to same-version registration).

### 4. Automatic Rollback
If any user request to the new version returns a 5xx response during a transition,
the new version entry is removed immediately and 100% of traffic reverts to the
old version. The deploying service can re-register to retry the transition.

### 5. Health Checks
The gateway periodically polls each registered service's health endpoint. Three
consecutive non-200 responses mark that instance as failed and remove it from the
registry. If all instances of a version are removed, the version group is removed.
If all versions for a host are removed, the host falls back to static config or
returns 404.

Health checks are only performed on active version pools. A version that is being
drained (replaced by a new version) is not health-checked.

### 6. Disk Persistence
Every mutation to the dynamic registry is written asynchronously to a JSON file on
disk (`dynamic_services.json`). On gateway restart, this file is loaded to restore
the registry to its last known state. Writes are atomic (write to a temp file then
rename) to prevent corruption.

### 7. Three-Layer Config Coexistence
Three configuration sources exist, checked in order on every request:

- **Dynamic services** (`dynamic_services.json`): the runtime registry managed by
  service self-registration. Checked first. Wins for any host it knows about.
- **Custom domains** (`custom_domains.json`): user-registered domains for multi-tenant
  services (e.g. writeinone users pointing their own domain at the gateway). Each entry
  maps a domain to a named service and carries SSL cert state. See
  `GATEWAY_CONFIG_SSL_AND_CUSTOM_DOMAINS.md` for the full spec.
- **Static services** (`gateway.yaml`): infrastructure-level routing declared by the
  operator. Used as final fallback. Replaces the flat `GATEWAY_SERVICES`,
  `LETSENCRYPT_DOMAINS`, and `DDNS_DOMAINS` environment variables. See
  `GATEWAY_CONFIG_SSL_AND_CUSTOM_DOMAINS.md` for the schema.

If no source matches the host, the gateway returns 404.

### 8. Internal-Only Registration API
The registration API is exposed on a separate port bound exclusively to internal
network interfaces (loopback and private network addresses). It is never reachable
from the public internet, analogous to how the metrics endpoint is protected, but
stricter by using a dedicated listener rather than authentication.

## Non-Goals

- The gateway will not notify services to shut down. Services manage their own
  lifecycle and shut down when appropriate.
- Explicit deregistration of backend instances is not supported. Services leave the
  registry only via health check eviction. Note: custom domain entries (the third config
  layer) do support explicit deletion via `DELETE /custom-domains/:domain` since a user
  may remove their domain at any time.
- No cross-node registry synchronization for backend instances. Each cluster node
  maintains its own independent registry. Custom domain cert files are synced to
  secondary nodes via the existing `CertificateManager` RPC mechanism.

## Future Work

### Elixir Client Library
A standalone Mix package (`elixir_gateway_client`) to be built after the gateway
side is stable. It would allow Elixir services to integrate with zero boilerplate:
one supervisor child and one plug.

Planned responsibilities:
- Auto-register on application startup, reading host, version, and health path
  from config. Version auto-detected from `Application.spec/2` or the
  `RELEASE_VERSION` env var set by Mix releases.
- Periodic re-registration as a heartbeat, so the service reappears in the
  registry automatically if the gateway restarts and loses its disk state.
- A `DrainPlug` that tracks in-flight requests with an atomic counter and blocks
  the OTP shutdown sequence until the counter reaches zero, ensuring graceful
  drain before the OS process exits.

Non-Elixir services only need to issue a periodic `POST /services` HTTP call,
so no client library is required for them.

## High Level Component Map

```
Startup
      │
      ▼
[ConfigLoader]                 ← reads gateway.yaml, performs ${} substitution,
                                  produces static routing table + SSL domain list
                                  + DDNS config (Namecheap or Cloudflare per service)

Internal Network
      │
      ▼
[Internal API Server]          ← separate port, internal interfaces only
      │
      ├──► [ServiceRegistry GenServer]    ← authoritative in-memory state (ETS)
      │          │
      │          ├──► [TransitionScheduler]   ← advances canary phases on timers
      │          ├──► [HealthChecker]         ← periodic polling, evicts failed instances
      │          └──► [DiskPersistence]       ← async atomic writes to dynamic_services.json
      │
      └──► [CustomDomainRegistry GenServer]  ← maps user domains to services + cert state
                 │
                 ├──► [AcmeClient]           ← issues HTTP-01 certs per custom domain
                 └──► [CertRenewalScheduler] ← daily scan, renews certs expiring in <30 days

Public Internet
      │
      ▼
[Existing pipeline: BotBlocker → RateLimiter → WebSocket → DomainRouter → ...]
                                                                  │
                                                    1. dynamic registry (ServiceRegistry)
                                                    2. custom domains (CustomDomainRegistry)
                                                    3. static config (gateway.yaml)
                                                    4. 404
```
