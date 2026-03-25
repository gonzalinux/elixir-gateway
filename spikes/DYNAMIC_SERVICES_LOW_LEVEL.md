# Dynamic Service Registration — Low Level Spec

## Data Structures

### ServiceEntry
Represents a single registered instance.

```
host          :: String          — e.g. "seveneat.com"
target        :: String          — e.g. "http://localhost:4001"
version       :: String          — opaque string, e.g. "a3f9c1" or "1.2.3"
health_path   :: String          — defaults to "/health"
registered_at :: DateTime (UTC)
```

### VersionGroup
All instances sharing the same host + version.

```
host              :: String
version           :: String
targets           :: [String]           — pool of registered targets
health_failures   :: %{target => int}   — consecutive failure count per target
state             :: :active | :draining
```

### TransitionState
Attached to a VersionGroup with state :active that is being phased in.

```
phases            :: [{duration_minutes :: int, percentage :: int}]
current_phase     :: int                — 0-based index into phases
phase_started_at  :: DateTime (UTC)
old_version       :: String             — version being replaced
```

### Registry Shape (ETS / GenServer state)
```
%{
  host => %{
    version_string => %VersionGroup{}
  }
}
```

At most two version groups per host at any time: one :active (being phased out,
draining) and one :active (being phased in, with a TransitionState attached).
The draining group has no TransitionState and receives the complement percentage.

---

## Module Breakdown

### `ElixirGateway.ServiceRegistry` (GenServer + ETS)
Single source of truth for the dynamic registry.

**Responsibilities:**
- Maintain the ETS table of version groups.
- Handle registration requests: create new group, add target to existing group,
  or start a transition if version differs from current active.
- Expose a lookup function used by DomainRouter: given a host, return a weighted
  list of targets across all active version groups.
- Evict a target on health check failure (called by HealthChecker).
- Advance a transition phase (called by TransitionScheduler).
- Complete a transition: set new version to 100%, remove old version group.
- Roll back a transition: remove new version group (called by RequestForwarder on
  5xx detection during transition).
- Notify DiskPersistence after every mutation.

**Key functions:**
- `register(payload)` → `:ok | {:error, reason}`
- `lookup(host)` → `[{target, weight}]` — list used for weighted random selection
- `evict_target(host, version, target)` → `:ok`
- `advance_phase(host, new_version)` → `:ok | :transition_complete`
- `rollback_transition(host, new_version)` → `:ok`
- `all_entries()` → full registry map (used by DiskPersistence and HealthChecker)

**Registration logic (inside handle_call):**
1. Look up existing version groups for `host`.
2. If none exist: create new VersionGroup with state :active, no transition.
3. If a group with same version exists: add target to its pool if not already
   present.
4. If a group with different version exists and it is :active:
   - Mark existing group state as :draining.
   - Create new VersionGroup with state :active.
   - Attach TransitionState to new group (phases from payload, phase 0,
     started_at = now, old_version = existing version string).
   - Notify TransitionScheduler to start timer for phase 0 duration.
5. If a transition is already in progress (one draining, one active-with-transition):
   reject registration with `{:error, :transition_in_progress}`.

**Weighted random selection (lookup):**
- If only one version group (no transition): return all targets with equal weight.
- If two version groups (transition active): return targets from new group at
  current phase percentage, targets from old group at (100 - percentage).
- Caller picks one target via weighted random.

---

### `ElixirGateway.TransitionScheduler` (GenServer)
Manages timers for phase advancement.

**Responsibilities:**
- Accept `schedule_phase(host, new_version, duration_ms)` calls from
  ServiceRegistry.
- After the timer fires, call `ServiceRegistry.advance_phase(host, new_version)`.
- If `advance_phase` returns `:transition_complete`, do nothing further (registry
  has already cleaned up).
- If it returns `:ok`, ServiceRegistry will call `schedule_phase` again for the
  next phase as part of its `advance_phase` logic.
- On gateway restart: ServiceRegistry restores state from disk including
  TransitionState. It recalculates remaining time for the current phase based on
  `phase_started_at` and schedules accordingly (negative or zero remaining time
  means advance immediately).

**Key functions:**
- `schedule_phase(host, version, duration_ms)` → `:ok`
- `cancel(host, version)` → `:ok` (called on rollback)

---

### `ElixirGateway.HealthChecker` (GenServer)
Periodic health polling for all active instances.

**Responsibilities:**
- On a configurable interval (default: 30 seconds), iterate all targets in all
  :active version groups across all hosts.
- Skip :draining version groups.
- For each target, make an HTTP GET to `target <> health_path` with a short
  timeout (default: 5 seconds).
- 200 response: reset failure count for that target.
- Non-200 or connection error: increment failure count.
- If failure count reaches 3: call `ServiceRegistry.evict_target/3`.
- Uses the existing `ElixirGateway.Finch` HTTP client.

**Configuration:**
- `health_check_interval_ms` — default 30_000
- `health_check_timeout_ms` — default 5_000
- `max_failures` — default 3

---

### `ElixirGateway.DiskPersistence` (GenServer)
Async atomic writer for the dynamic registry.

**Responsibilities:**
- Accept `persist(registry_map)` calls from ServiceRegistry (cast, not call).
- Serialize the registry map to JSON.
- Write to `{data_dir}/dynamic_services.json.tmp`.
- Rename to `{data_dir}/dynamic_services.json`.
- On write error, log a warning but do not crash.

**Startup loading:**
- Called by ServiceRegistry during `init/1`.
- Read `dynamic_services.json` if it exists.
- Deserialize and populate ETS.
- If the file is missing or malformed, start with an empty registry and log a
  warning.
- After loading, for any VersionGroup with an active TransitionState, call
  TransitionScheduler to reschedule the current phase with adjusted remaining time.

**Configuration:**
- `data_dir` — directory for the JSON file. Defaults to the app's priv directory.
  Configurable via `DYNAMIC_SERVICES_DIR` env var.

---

### `ElixirGateway.InternalServer` (Bandit/Plug)
Separate HTTP listener for the registration API.

**Responsibilities:**
- Start a second Bandit listener bound to internal interfaces only.
- Accept `POST /services` for service registration.
- Return structured JSON responses.
- Reject requests not originating from loopback or RFC-1918 addresses
  (10.x, 172.16-31.x, 192.168.x, 127.x).

**Binding:**
- Listen on `127.0.0.1` and optionally a configured internal interface IP.
- Port configurable via `INTERNAL_API_PORT` env var (default: 4001, or whatever
  does not conflict with existing services).
- If the machine has a private network interface IP configured via
  `INTERNAL_API_BIND_IP`, bind to that address as well (start two listeners or
  use `0.0.0.0` with IP filtering at the plug level).

---

### `ElixirGateway.InternalController` (Plug router)
Handles requests on the internal server.

**Endpoints:**

`POST /services`
- Parse JSON body.
- Validate required fields: `host`, `target`, `version`.
- Optional fields: `health_path` (default `/health`), `transition` (list of phases).
- Validate transition: each phase must have `duration_minutes` (integer > 0) and
  `percentage` (integer 1–99, strictly increasing across phases).
- On validation failure: 422 with error detail.
- Call `ServiceRegistry.register/1`.
- On success: 200 with current registry state for that host.
- On `{:error, :transition_in_progress}`: 409 Conflict.

`GET /services` (optional, for observability)
- Return full dynamic registry as JSON. Useful for debugging.

`POST /custom-domains`
- Validate required fields: `domain` (string), `service` (string, must match a known
  service name in gateway.yaml or dynamic registry).
- Add to `CustomDomainRegistry` with `cert_state: "pending"`.
- Trigger async ACME HTTP-01 cert issuance.
- Response 200: `{ "domain": "...", "cert_state": "pending" }`.
- Response 422: validation error.

`GET /custom-domains/:domain`
- Return current state of a registered custom domain.
- Response 200: `{ "domain": "...", "cert_state": "pending|issued|failed", "expires_at": "..." }`.
- Response 404: domain not registered.

`DELETE /custom-domains/:domain`
- Remove domain from `CustomDomainRegistry`.
- Delete cert files from disk (`certs/custom/:domain/`).
- Response 200: ok.
- Called by the upstream service when a user removes their custom domain.

---

### Changes to `ElixirGatewayWeb.Plugs.DomainRouter`

**Current behavior:**
Reads `Application.get_env(:elixirgateway, :gateway)[:services]` on every request.

**New behavior:**
1. Call `ServiceRegistry.lookup(host)` first.
2. If it returns a non-empty list: pick a target via weighted random, assign to
   `conn.assigns[:target_url]`.
3. If it returns empty: call `CustomDomainRegistry.lookup(host)`.
4. If it returns a match: resolve the service name to a target (check dynamic registry
   first, then static config), assign to `conn.assigns[:target_url]`. Preserve the
   original `Host` header — the upstream service uses it to identify the tenant.
5. If no custom domain match: fall through to static config from `ConfigLoader` (replaces
   the previous `Application.get_env(:elixirgateway, :gateway)[:services]` lookup).
6. If no static match: 404.

**Weighted random selection (in DomainRouter, not registry):**
- Receive `[{target, weight}, ...]` from registry.
- Sum weights, pick a random number in range, walk the list.
- For single-version pools all weights are equal so this degrades to uniform random.

---

### Changes to `ElixirGatewayWeb.Plugs.RequestForwarder`

**New behavior:**
- After receiving a response, if the request was routed to a target that belongs
  to an in-transition version group AND the response status is 5xx:
  - Call `ServiceRegistry.rollback_transition(host, new_version)`.
  - This information must be threaded through conn assigns by DomainRouter:
    `conn.assigns[:routed_version]` and `conn.assigns[:in_transition]`.

---

### Changes to `ElixirGateway.Application`

Add to the supervision tree (before Endpoint):
```
ElixirGateway.ConfigLoader
ElixirGateway.DiskPersistence
ElixirGateway.ServiceRegistry
ElixirGateway.TransitionScheduler
ElixirGateway.HealthChecker
ElixirGateway.CustomDomainRegistry
ElixirGateway.AcmeClient
ElixirGateway.CertRenewalScheduler
ElixirGateway.InternalServer
```

Order matters:
- `ConfigLoader` must start first — all other components read static config from it.
- `DiskPersistence` before `ServiceRegistry` — registry reads disk during its own init.
- `ServiceRegistry` before `HealthChecker` and `TransitionScheduler`.
- `AcmeClient` before `CustomDomainRegistry` — registry triggers cert issuance on
  startup for any domain with `cert_state: "pending"`.

Revised order:
1. ConfigLoader (reads gateway.yaml, makes static config available)
2. DiskPersistence
3. ServiceRegistry (reads disk in init, then schedules any in-progress transitions)
4. TransitionScheduler
5. HealthChecker
6. AcmeClient
7. CustomDomainRegistry (reads custom_domains.json, resumes pending cert issuances)
8. CertRenewalScheduler
9. InternalServer
10. ... existing children ...
11. Endpoint

---

## Registration API Payload Reference

**POST /services**

Required:
- `host` — string, the public hostname (e.g. `"seveneat.com"`)
- `target` — string, full base URL of the service (e.g. `"http://localhost:4001"`)
- `version` — string, opaque version identifier (e.g. `"a3f9c1"`, `"1.2.3"`)

Optional:
- `health_path` — string, path for health checks (default: `"/health"`)
- `transition` — array of phase objects, only meaningful when registering a new
  version over an existing one:
  - `duration_minutes` — positive integer, how long to hold this percentage
  - `percentage` — integer 1–99, traffic share for the new version during this phase
  - Phases must be listed in order; percentages must be strictly increasing.
  - No final 100% step is needed; the gateway applies 100% automatically after the
    last phase.

**Example — first registration:**
```json
{
  "host": "seveneat.com",
  "target": "http://localhost:4000",
  "version": "a3f9c1",
  "health_path": "/health"
}
```

**Example — canary deployment:**
```json
{
  "host": "seveneat.com",
  "target": "http://localhost:4001",
  "version": "b7d2e4",
  "health_path": "/health",
  "transition": [
    { "duration_minutes": 1, "percentage": 10 },
    { "duration_minutes": 5, "percentage": 50 }
  ]
}
```

**Example — horizontal scale-out (same version, second instance):**
```json
{
  "host": "seveneat.com",
  "target": "http://localhost:4002",
  "version": "b7d2e4"
}
```

---

## Configuration Reference

| Env Var                  | Default        | Description                                  |
|--------------------------|----------------|----------------------------------------------|
| `GATEWAY_CONFIG_FILE`    | `priv/gateway.yaml` | Path to gateway.yaml. See `GATEWAY_CONFIG_SSL_AND_CUSTOM_DOMAINS.md`. |
| `INTERNAL_API_PORT`      | `4001`         | Port for the internal registration API       |
| `INTERNAL_API_BIND_IP`   | `127.0.0.1`    | IP to bind the internal listener to          |
| `DYNAMIC_SERVICES_DIR`   | priv dir       | Directory for dynamic_services.json and custom_domains.json |
| `HEALTH_CHECK_INTERVAL`  | `30000`        | Health check interval in milliseconds        |
| `HEALTH_CHECK_TIMEOUT`   | `5000`         | Per-request health check timeout in ms       |
| `HEALTH_MAX_FAILURES`    | `3`            | Consecutive failures before eviction         |

---

## File Layout

```
lib/elixir_gateway/
  config_loader.ex             ← reads gateway.yaml, ${} substitution, exposes static config
  services/
    service_registry.ex        ← GenServer + ETS
    transition_scheduler.ex    ← timer management
    health_checker.ex          ← polling loop
    disk_persistence.ex        ← async JSON writer
    internal_server.ex         ← Bandit listener setup
    internal_controller.ex     ← Plug router + request handling
  custom_domains/
    custom_domain_registry.ex  ← GenServer + ETS, cert state tracking
    acme_client.ex             ← ACME v2 HTTP-01 cert issuance via Req
    cert_renewal_scheduler.ex  ← daily scan, renews certs expiring within 30 days
  cluster/
    ddns/
      namecheap.ex             ← existing
      cloudflare.ex            ← new: Cloudflare DNS A record updater

data/
  dynamic_services.json        ← persisted service registry (written at runtime)
  custom_domains.json          ← persisted custom domain registry (written at runtime)

certs/
  site_encrypt/                ← managed by SiteEncrypt (existing domains, HTTP-01)
  wildcard/                    ← managed by acme.sh (wildcard certs, DNS-01)
    writeinone.com/
      cert.pem
      key.pem
  custom/                      ← managed by AcmeClient (per user-domain certs, HTTP-01)
    blog.johndoe.com/
      cert.pem
      key.pem
```

---

## Edge Cases

- **Gateway restarts mid-transition**: Phase timer is recalculated from
  `phase_started_at`. If elapsed time already exceeds phase duration, advance
  immediately (or skip to the appropriate phase).
- **Target already in pool**: Re-registration with same host + version + target is
  a no-op (idempotent). Useful for services that register on startup regardless.
- **Transition on host with no existing version**: No transition is started even if
  a schedule is provided. The new version goes directly to 100%.
- **All instances of both versions evicted during transition**: Host entry removed.
  DomainRouter falls through to custom domain registry, then static config, then 404.
  No orphaned TransitionState.
- **Internal API port conflict**: Document clearly in env var config. The default
  must not collide with common development service ports.
- **Cluster nodes**: No sync between nodes. A service registers on the node it can
  reach on the internal network. If the home server runs service A and the cloud
  node does not, the load distributor's existing "skip if no route" behavior
  handles this correctly — no changes needed to the cluster layer.

---

## Future Work

### `elixir_gateway_client` Hex Package

> Not part of this implementation. To be built once the gateway-side API is stable.

A standalone Mix package that Elixir services add as a dependency. The full design
is captured in the high-level spec. Implementation notes for when the time comes:

**Modules:**
- `GatewayClient` — supervisor entry point, accepts config keyword list as child
  spec argument.
- `GatewayClient.Registrar` — GenServer that calls `POST /services` on init and
  on a configurable heartbeat interval (default: 5 minutes). Uses a simple
  `Finch` or `Req` HTTP client.
- `GatewayClient.DrainPlug` — Plug that wraps each request with an atomic counter
  increment/decrement via `:atomics`. The `GatewayClient` supervisor's
  `terminate/2` callback waits for the counter to reach zero with a configurable
  timeout (default: 30 seconds) before returning, blocking OTP shutdown.

**Version resolution order:**
1. Explicit `:version` key in config.
2. `System.get_env("RELEASE_VERSION")` — set automatically by `mix release`.
3. `Application.spec(otp_app, :vsn) |> to_string()` — from mix.exs version field.

**Config shape:**
```
gateway_url:   "http://10.0.0.1:4001"   # required
host:          "seveneat.com"            # required
health_path:   "/health"                 # optional, default "/health"
version:       "a3f9c1"                  # optional, auto-detected if omitted
heartbeat_ms:  300_000                   # optional, default 5 minutes
drain_timeout: 30_000                    # optional, default 30 seconds
transition:    [...]                     # optional, passed through to gateway
```
