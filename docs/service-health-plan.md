# Service Health Checks & Failover — Plan

Goal: ping the health endpoint of every service that opts in every ~1.5s. When a service is down on
this node but healthy on a peer, route its requests to the peer.

## Decisions

- **HTTP checks only**, `GET <target><health_path>`.
- **Opt-in per service: setting `health_path` in `gateway.yaml` enables the check.** No
  `health_path` (or an empty one) = no check, never marked down, never fails over. A
  default would mark every service without a `/health` endpoint down (404) and move its
  traffic around.
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
  (request processes), `read_concurrency: true`. Only down entries are stored
  (`{{node, domain}, :ko}`); missing entry = healthy.
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
      `services` with a non-empty `health_path`, store it under `:gateway, :health`
- [x] Call it from `apply_config/1`
- [x] Getter `get_health_services/0` that always returns a map (`%{}` when unset)
- [x] Tests: default path and an override, `health_domain` for wildcard / default domains
- [x] `default` domain stored as `default_any` (same key as the routing map / `:service_key`)

Learn: `Enum.map` / `Enum.flat_map`, `Map.get/3` defaults, keeping types in sync with code.

### 2. The check
- [x] `{Finch, name: ElixirGateway.HealthFinch, ...}` in the supervision tree, before `ServiceHealth`
- [x] `check(service_check, timeout_ms) :: :ok | :ko`:
  URL `target <> health_path`, `Host` = `health_domain`, `request_timeout: timeout_ms`
- [x] Log status / reason on failure
- [x] Tests with Bypass: 200 → `:ok`; 204, 500 → `:ko`; `Bypass.down/1` → `:ko`; `Host` header sent

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
- [x] Tests for `update_health/2` thresholds (down on 4th failure, up on 3rd success)
- [ ] Make the state a `%ServiceHealth{}` struct with `@type t`
- [ ] `@spec` on `healthy?/1`

Learn: `handle_continue` vs `send(self(), ...)`, scheduling after the work finishes,
hysteresis.

Try it: run the gateway, stop a backend, watch it go down and come back in the logs.

### 4. Quick detection in the request path
- [x] `ServiceHealth.set_unhealthy(host)`: `cast`, maps host → service via `domain_to_service`,
      counts as one failure (still 4 to go down: a single error could be a blip)
- [x] Unknown host in `handle_cast` must not crash (uses `Map.fetch` on `domain_to_service`)
- [x] `RequestForwarder.forward_request` calls `ServiceHealth.set_unhealthy(conn.assigns[:service_key])`
      in the `{:error, reason, conn}` branch. Note: this fires on **any** forwarding error
      (timeouts included), not only `econnrefused`; 4 slow requests in a row would mark
      the service down

Learn: `cast` vs `call`; why a request process must never block on a background GenServer.

### 5. Share health with peers
ETS only holds **down** entries, `{{node, domain}, :ko}`, for this node and peers alike.
A missing row = healthy. Messages are `GenServer.cast`/`abcast` from the `ServiceHealth`
process itself (async, and ordered between two processes), not `RPC` + `Task`.

- [x] 5.1 Local keys: `save_update/2` inserts `{{node(), domain}, :ko}` on down and
      deletes `{node(), domain}` on up; `healthy?(service_key, node)` looks up
      `{node, service_key}` (no default for `node`: pass `node()` for local)
- [x] 5.2 `down_domains(state)` helper: domains of services with `health: :ko`
- [x] 5.3 `handle_cast({:peer_down_list, peer, domains})`: `match_delete {{peer, :_}, :_}`,
      then insert `{{peer, d}, :ko}` for each
- [x] 5.4 `handle_cast({:peer_update, peer, domains, :ko | :ok})`: insert or delete those rows
- [x] 5.5 `init/1`: `:net_kernel.monitor_nodes(true)` (plain, not `node_type: :all`: we don't
      read the `info` element, and hidden nodes like remote consoles never run
      `ServiceHealth`; also consistent with `Node.list()`). Messages are 2-tuples
- [x] 5.6 `handle_info({:nodeup, peer})`: cast `{:peer_down_list, node(), down_domains(state)}`
      to `{__MODULE__, peer}`
- [x] 5.7 `handle_info({:nodedown, peer})`: `match_delete {{peer, :_}, :_}`
- [x] 5.8 `save_update/2`: on a flip, one `abcast(Node.list(), __MODULE__, {:peer_update, node(), domains, health})`
      per flip (outside the per-domain loop). `Node.list()` explicitly, since the default
      node list includes `node()` itself
- [x] 5.9 `init/1`: `abcast(Node.list(), __MODULE__, {:sync_request, node()})`;
      `handle_cast({:sync_request, peer})` replies with `:peer_down_list` (recovers peer
      state after this process restarts)
- [x] Catch-all `handle_cast/2` and `handle_info/2` clauses (log and ignore), so an
      unexpected message (e.g. from a peer on another version during a rolling deploy)
      doesn't crash the GenServer and wipe the table
- [x] `@spec` on `healthy?/2`
- [x] Tests (no second node needed), with a fake peer like `:fake@host`:
  - `:peer_down_list` → `healthy?("a.com", :fake@host) == false`
  - `:peer_update` with `:ok` → healthy again
  - a second `:peer_down_list` without a domain replaces the old rows
  - `{:nodedown, :fake@host}` → that peer's rows are gone

Later hardening (step 6): a peer receiving a forwarded request for a service it knows is
down replies `{:error, :service_down}`; the sender marks it and processes locally.

Learn: `:net_kernel.monitor_nodes/1`, `GenServer.cast({name, node}, msg)` / `abcast/3`,
`:ets.match_delete/2`, message ordering guarantees between two processes.

### 6. Routing
- [x] `DomainRouter` assigns the routing key it matched as `conn.assigns[:service_key]`
      (`resolve_service_entry/1` returns `{service_key, target_url}`)
- [x] Tests for `resolve_service_entry/1`: exact, wildcard and `default_any` keys
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
