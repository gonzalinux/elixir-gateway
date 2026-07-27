# Plan: Replace RPC request forwarding with HTTP over WireGuard

> Status: **design agreed, not implemented**. Builds on the streaming forwarder
> work (reference impl on branch `streaming-forwarder-ai`).

## The problem

Inter-node forwarding today (`RequestForwarder.forward_to_remote_node/2` →
`handle_rpc({:execute_forwarded_request, ...})`) serializes the **whole request
body** into one `:rpc.call` and returns the **whole response** the same way.

- Erlang distribution fragments large messages for transport (~64KB fragments),
  but delivers them **atomically**: the receiving process only sees the message
  once fully reassembled in its mailbox. There is no incremental read.
- The full body must also exist in memory on the sender before handing it to
  the distribution layer.
- So 100 concurrent 20MB uploads ≈ 2GB in mailboxes/buffers in flight, plus
  copies. Double buffering (both nodes hold the full body and full response).

## Alternatives considered

### RPC streaming (rejected for now)

Spawn a linked worker on the peer; send body chunks as messages; peer's Finch
body is a `Stream.resource` reading its mailbox; response chunks sent back as
messages; `spawn_link` propagates client-disconnect to the peer worker.

- Kills all the HTTP-approach traps (no pipeline on peer → no loops, no rate
  limit issue, no spoofing, no port discovery).
- BUT: mailboxes are unbounded → must hand-roll a credit-based back-pressure
  protocol in both directions. That's where the subtle bugs live.
- Great future learning exercise on Erlang distribution; not the pragmatic choice.

### 302/307 redirect to the assigned node (rejected)

Return `307 Location: <node-B-url>` and let the client talk to node B directly
(the S3-style pattern). Rejected because:

- DNS for the served domains points at the primary — redirecting to the same
  domain loops; redirecting to per-node hostnames/IPs requires new public DNS,
  per-node TLS certs and DDNS records.
- 302 rewrites POST→GET in most clients; 307/308 preserve the body but many
  API clients don't follow redirects with bodies (or at all).
- Every request pays an extra round trip (client base URL never changes).
- Session cookies are domain-scoped → not sent to the node's hostname →
  sticky-session identification breaks.
- WebSocket upgrades can't be redirected.
- CORS becomes cross-origin.
- It solves a different problem (offloading body bandwidth from the primary)
  than ours (memory buffering), which HTTP forwarding already fixes.

### HTTP forwarding via a dedicated internal route (CHOSEN)Open an internal route protected by auth, reachable only over WireGuard, that
takes a **different path than the exposed routes**. Path separation (instead of
marker headers) dissolves three of the four traps of naive HTTP forwarding:

- **Routing loops**: internal pipeline has no `LoadDistributionRouter` → the
  peer always processes locally. (Loop trap existed because
  `register_session_on_remote` only writes to the *primary's* ETS, so the peer
  would see a `:new_session` and might route the request back.)
- **Rate limiter / BotBlocker exhaustion**: simply not in the internal pipeline
  (otherwise all forwarded traffic would share the primary's IP and burn the
  per-IP limit).
- **Spoofing**: `MetricsAuthPlug` IP auth + WireGuard = only the private
  network can reach the route.

## The design

### Peer side (receives forwarded requests)

```elixir
pipeline :cluster_forward do
  plug(ElixirGatewayWeb.Plugs.MetricsAuthPlug)   # or a dedicated ClusterAuthPlug
  plug(ElixirGatewayWeb.Plugs.DomainRouter)      # resolves service from original Host header
  plug(ElixirGatewayWeb.Plugs.RequestForwarder)  # streams to the local backend
end

# router.ex — BEFORE the catch-all gateway scope:
scope "/cluster-forward", ElixirGatewayWeb do
  pipe_through(:cluster_forward)
  match(:*, "/*path", GatewayController, :proxy)
end
```

Note: `RequestForwarder` with no `:target_node` assign falls into its `nil`
branch → `ConnectionRegistry.get_node` → `:new_session` → `process_locally`.
Works, but assigning `:local` explicitly would be cleaner.

### Primary side (forwards)

`forward_to_remote_node(conn, node)` becomes:

1. Build peer URL: `http://<peer-ip>:<port>/cluster-forward<path>?<query>`
2. Set headers: `Host: <original-host>`, `X-Forwarded-For: <real-client-ip>`
3. Stream request body out, stream response back — reuse the streaming
   `forward_request` almost verbatim.
4. On peer unreachable → fall back to local (see decision 4 below).

### Deletions

- `handle_rpc({:execute_forwarded_request, ...})` and its tests
- RPC plumbing in `RequestForwarder` (`use ElixirGateway.Cluster.RPC` if unused
  elsewhere — check `CertificateManager` etc. before removing the module)

## Open decisions (decide explicitly, don't discover)

1. **Port discovery**: `CLUSTER_PEERS` is `name@ip:dist-port` (Erlang
   distribution port, NOT the gateway HTTP port). Options: convention (same
   HTTP port on all nodes, read from endpoint config) or extend the peer
   config format with the HTTP port.
2. **Auth precision**: `MetricsAuthPlug` IP fallback allows ALL private
   networks — includes the LAN, so any LAN device could bypass rate limits via
   this route. Options: dedicated plug checking `conn.remote_ip` against peer
   IPs parsed from `CLUSTER_PEERS`, or require `METRICS_AUTH_TOKEN` here.
3. **X-Forwarded-For**: primary sets it so the backend sees the real client IP
   and peer logs are meaningful. Safe to trust incoming XFF on this route since
   only peers reach it.
4. **Fallback semantics**: falling back to local processing after the peer
   fails is only possible if the failure happens BEFORE the first body byte is
   sent (the stream is single-use). Decide: fallback only for bodyless
   requests, or buffer small bodies and stream only big ones.
   (Pre-existing related bug: today's RPC path consumes the body and then
   retries locally with an empty body on `:node_down`.)

## Why this composes with streaming

Primary streams client→peer, peer streams peer→backend, response streams back
the same way: end-to-end O(chunk) memory instead of O(body) on two nodes.
The client↔primary half is identical in every design — it's the
`streaming-forwarder-ai` exercise already in flight.
