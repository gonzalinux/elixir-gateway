# Service Health Checks & Failover — Plan

Goal: ping every service's `/health` endpoint every ~1.5s. When a service is down on
this node but healthy on a peer, route its requests to the peer.

## Decisions

- **HTTP checks only**, `GET <target><health_path>`; `health_path` defaults to `/health`,
  overridable per service in `gateway.yaml`.
- **Only 2xx is healthy.** A 404 or a redirect from a dedicated health endpoint means
  something is misconfigured: mark down and log the status.
- **Separate Finch pool** (`ElixirGateway.HealthFinch`), so checks never wait behind real traffic.
- **Check per service** (the YAML service name), sending the service's first non-wildcard
  domain as the `Host` header (none for `default_any`). Backends may route by host.
- **Store and share results per host**: one ETS entry per domain of the service. Hosts are
  the key nodes already agree on (`node_has_service?/2`); service names are local to
  each node's `gateway.yaml`.
- **ETS, not GenServer state, for reads**: one writer (the GenServer), many readers
  (request processes), `read_concurrency: true`. Missing entry = healthy.
- **Hysteresis**: down after N consecutive failures, up after M consecutive successes.
- **Failover doesn't re-register sessions**: traffic returns on its own once the service recovers.

## Steps

### 0. Groundwork
- [x] `ServiceHealth` GenServer skeleton: ETS table, config with defaults
- [x] `ConfigLoader.get_services/0` with `routing_map()` spec, returns `%{}` when unset
- [x] Dialyxir installed (`mix dialyzer`)
- [x] `write_concurrency` removed from the health table
- [x] Health table `:protected` instead of `:public` (only the owner writes)

### 1. Data the checker needs (`config_loader.ex`)
- [x] `service_health_check()` type: `name`, `target`, `domains`, `health_path`
- [x] Implement `apply_health_checks/1`: build the list in a pass over `services`, store it
      under `:gateway, :service_checks`, `health_path` defaults to `"/health"`
- [x] Call it from `apply_config/1`
- [x] Getter that always returns a list (`[]` when unset)
- [ ] Tests: default path and an override

Learn: `Enum.map` / `Enum.flat_map`, `Map.get/3` defaults, keeping types in sync with code.

### 2. The check
- [x] `{Finch, name: ElixirGateway.HealthFinch, ...}` in the supervision tree, before `ServiceHealth`
- [ ] `check(service_check, timeout_ms) :: :up | :down`
  - URL `target <> health_path`, `Host` = first non-wildcard domain
  - `200..299` → `:up`; anything else → `:down`, log status / reason
- [ ] Tests with Bypass: 200, 500, `Bypass.down/1`

Learn: `Finch.build/4`, `Finch.request/3` (`receive_timeout`, `pool_timeout`), guards in
`case`, supervision tree start order.

### 3. The loop
- [ ] Build state from the service checks (not `get_services/0`, which is per host)
- [ ] `init/1` returns `{:ok, state, {:continue, :check}}`; handle in `handle_continue/2`
- [ ] `handle_info(:check, state)`:
  - `Task.async_stream/3` with `timeout:` and `on_timeout: :kill_task`; `{:exit, _}` = `:down`
  - Update counters; flip state at the thresholds
  - On a flip, write `{host_key, status}` to ETS for each of the service's domains; log it
  - `Process.send_after(self(), :check, interval)`
- [ ] Start `ServiceHealth` in the supervision tree
- [ ] Public `healthy?(host_key)` reading ETS directly
- [ ] Make the state a `%ServiceHealth{}` struct with `@type t`

Learn: `handle_continue` vs `send(self(), ...)`, `Task.async_stream` timeouts, scheduling
after the work finishes, hysteresis.

Try it: run the gateway, stop a backend, watch it go down and come back in the logs.

### 4. Quick detection in the request path
- [ ] In `RequestForwarder.forward_request`, on `%Mint.TransportError{reason: :econnrefused}`,
      `cast` to `ServiceHealth` to mark the service down immediately

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
