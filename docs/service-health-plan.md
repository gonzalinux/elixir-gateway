# Service Health Checks & Failover — Plan

Goal: ping every service's `/health` endpoint every ~1.5s. When a service is down on
this node but healthy on a peer, route its requests to the peer.

## Decisions

- **HTTP checks only**, `GET <target><health_path>`; `health_path` defaults to `/health`,
  overridable per service in `gateway.yaml`.
- **Only exactly 200 is healthy.** Anything else (204, 404, a redirect...) from a dedicated
  health endpoint means something is misconfigured: mark down and log the status.
- **Separate Finch pool** (`ElixirGateway.HealthFinch`), so checks never wait behind real traffic.
- **Check per service** (the YAML service name), sending a `health_domain` as the `Host`
  header: the shortest domain of the service, with a leading `*` replaced by `health`
  (`*.example.com` → `health.example.com`); none for `default`/`default_any`.
  Backends may route by host.
- **Store and share results per host**: one ETS entry per domain of the service. Hosts are
  the key nodes already agree on (`node_has_service?/2`); service names are local to
  each node's `gateway.yaml`.
- **ETS, not GenServer state, for reads**: one writer (the GenServer), many readers
  (request processes), `read_concurrency: true`. Missing entry = healthy.
- **Hysteresis**: down after 4 consecutive failures, up after 3 consecutive successes
  (thresholds hardcoded in `update_health/2` guards). Status values are `:ok` / `:ko`.
- **One timer per service** instead of `Task.async_stream` over all services: each service
  schedules its own `{:check, name}` message, so a slow service doesn't hold back the
  others' schedules. Checks still run one at a time inside the GenServer (each can block
  it for up to `timeout_ms`).
- **Failover doesn't re-register sessions**: traffic returns on its own once the service recovers.

## Steps

### 0. Groundwork
- [x] `ServiceHealth` GenServer skeleton: ETS table, config with defaults
- [x] `ConfigLoader.get_services/0` with `routing_map()` spec, returns `%{}` when unset
- [x] Dialyxir installed (`mix dialyzer`)
- [x] `write_concurrency` removed from the health table
- [x] Health table `:protected` instead of `:public` (only the owner writes)

### 1. Data the checker needs (`config_loader.ex`)
- [x] `service_health_check()` type: `name`, `target`, `domains`, `health_path`, `health_domain`
- [x] Implement `apply_health_checks/1`: build a map keyed by service name in a pass over
      `services`, store it under `:gateway, :health`, `health_path` defaults to `"/health"`
- [x] Call it from `apply_config/1`
- [x] Getter `get_health_services/0` that always returns a map (`%{}` when unset)
- [ ] Tests: default path and an override, `health_domain` for wildcard / default domains

Learn: `Enum.map` / `Enum.flat_map`, `Map.get/3` defaults, keeping types in sync with code.

### 2. The check
- [x] `{Finch, name: ElixirGateway.HealthFinch, ...}` in the supervision tree, before `ServiceHealth`
- [x] `check(service_check, timeout_ms) :: :ok | :ko`:
  URL `target <> health_path`, `Host` = `health_domain`, `request_timeout: timeout_ms`
- [x] Log status / reason on failure
- [ ] Tests with Bypass: 200 → `:ok`; 204, 500 → `:ko`; `Bypass.down/1` → `:ko`; `Host` header sent

Learn: `Finch.build/4`, `Finch.request/3` (`receive_timeout`, `pool_timeout`), guards in
`case`, supervision tree start order.

### 3. The loop
- [x] Build state from `get_health_services/0` (not `get_services/0`, which is per host),
      adding `health: :ok, ko_counter: 0, ok_counter: 0` per service
- [x] `init/1` schedules a `{:check, name}` per service with `Process.send_after/3`
      (first check after one interval, instead of `handle_continue`)
- [x] `handle_info({:check, name}, state)`:
  - Update counters via `update_health/2`; flip state at the thresholds
  - On a flip, write `{domain, status}` to ETS for each of the service's domains; log it
  - `Process.send_after(self(), {:check, name}, interval)` after the work finishes
- [x] Start `ServiceHealth` in the supervision tree
- [x] Public `healthy?(host_key)` reading ETS directly (healthy if missing or no table)
- [ ] Tests for `update_health/2` thresholds (down on 4th failure, up on 3rd success)
- [ ] Make the state a `%ServiceHealth{}` struct with `@type t`
- [ ] `@spec` on `healthy?/1`

Learn: `handle_continue` vs `send(self(), ...)`, scheduling after the work finishes,
hysteresis.

Try it: run the gateway, stop a backend, watch it go down and come back in the logs.

### 4. Quick detection in the request path
- [x] `ServiceHealth.set_unhealthy(host)`: `cast`, maps host → service via `domain_to_service`,
      counts as one failure (still 4 to go down: a single error could be a blip)
- [ ] Unknown host in `handle_cast` must not crash (use `Map.fetch` on `domain_to_service`)
- [ ] In `RequestForwarder.forward_request`, on `%Mint.TransportError{reason: :econnrefused}`,
      call `ServiceHealth.set_unhealthy/1`

Learn: `cast` vs `call`; why a request process must never block on a background GenServer.

### 5. Share health with peers
- [ ] On `:nodeup`, send the full table to the new peer (pattern: `LoadDistributor`'s `:nodeup`)
- [ ] On each flip, send `{node(), host_key, status}` to all peers
- [ ] `handle_rpc/1` stores peer entries keyed by `{node, host_key}`
- [ ] On `:nodedown`, delete that node's entries

Learn: `ElixirGateway.Cluster.RPC` (`rpc.ex`), `:net_kernel.monitor_nodes/1`,
`:ets.match_delete/2`, message ordering (a change arriving before the full state).

### 6. Routing
- [ ] `DomainRouter` assigns the routing key it matched (e.g. `conn.assigns[:service_key]`)
- [ ] `LoadDistributionRouter`, before the load-distribution check, so failover works
      even when load distribution is off:
  - local down, peer healthy → `{:remote, peer}`
  - pinned to a peer whose service is down → `:local`
  - down everywhere → `:local`
- [ ] Plug tests writing fake health entries to ETS

Learn: composing plugs, `Plug.Test`, keeping decisions in one place.

### 7. Metrics
- [ ] `elixirgateway_service_healthy{service, node}` gauge in `prom_ex/plugins/gateway.ex`
- [ ] Optional: counter for failover routing decisions

Learn: PromEx polling vs event metrics, label cardinality.

## Along the way
- `mix dialyzer` after each step
- `@spec` on public functions as you write them
