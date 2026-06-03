# Inter-Node Forwarding: RPC vs Streaming HTTP — Design Findings

> Status: exploratory notes, not yet implemented. Captured from a design
> discussion to revisit later. The current code still uses RPC forwarding.

## Context

The gateway uses a **single active ingress** topology: DNS points at the primary
node, which receives all traffic and distributes requests to secondaries based on
weights (`LoadDistributionRouter` → `RequestForwarder`). Failover promotes a
secondary by updating DNS (~1 minute propagation).

Today, when a request is routed to a remote node, `RequestForwarder` serializes the
request and ships it over **Erlang RPC** (`forward_to_remote_node/2` →
`handle_rpc/1`). This note records why that mechanism is suboptimal for the data
plane and what a streaming HTTP forward would look like instead.

## Key finding: the primary is always in the data path

As long as DNS points only at the primary, **the primary's NIC carries every byte,
both directions**, no matter the forwarding mechanism. RPC, L4, or L7 only change
*how* bytes pass through the primary, not *whether* they do. Bandwidth through the
primary is identical across all options. Only **multi-active DNS** (clients
connecting directly to secondaries) would change that — at the cost of reopening the
rate-limit/session-consistency questions that the single-ingress design avoids.

So the comparison below is **not** about moving fewer bytes. It is about:

1. **Memory footprint** — buffering vs streaming.
2. **Which connection carries the data** — the shared Erlang distribution channel
   vs a dedicated socket.

## Why RPC is the wrong tool for the data plane

### 1. It forces full-body buffering

RPC ships a complete Erlang term, so the whole body must be materialized first.
Current code (`read_remaining_body/2`) does exactly this:

```elixir
{:more, partial_body, conn} -> read_remaining_body(conn, acc_body <> partial_body)
```

`acc_body <> partial_body` accumulates the entire body (up to 20MB) into one binary,
then `term_to_binary` makes a *second* ~20MB copy to serialize it. The secondary
decodes back to 20MB, and `Finch.request` buffers the full response body too. Peak:
~40MB per request on each node. With 100 concurrent 20MB uploads: ~4GB+ resident.

### 2. It congests the Erlang distribution channel

All inter-node traffic — RPC forwards, cluster heartbeats (`net_tick`), cert sync,
cross-node GenServer calls — shares **one TCP connection per node pair**. Pushing
large payloads through it competes with control traffic and hits `dist_buf_busy_limit`
backpressure (which *suspends the sending process*).

Mitigation that already exists: **OTP ≥22 auto-fragments** large distribution
messages (~64KB fragments) so heartbeats can interleave — this makes a *spurious
nodedown* less likely than first assumed. But fragmentation does not move the traffic
off the channel; it only prevents one big message from monopolizing it. Sustained
volume still saturates the pipe the cluster's health depends on.

### Why "just chunk the RPC" doesn't solve it

Sending twenty 1MB RPC messages instead of one 20MB term fixes the **memory** problem
but not the **channel** problem (still on the distribution connection), and
reintroduces **backpressure** as a problem:

- With a real TCP stream, flow control is free and end-to-end: a slow consumer closes
  the TCP window, your `write` blocks, which backpressures your `read` from the client.
- With chunked RPC messages you lose that. Fire-and-forget (`cast`) piles chunks in
  the secondary's process mailbox (unbounded growth — worse, on the other node).
  Request-reply (`call`) per chunk serializes into a latency-bound ping-pong.
- Doing it correctly means hand-rolling windowing/acks, in-order reassembly,
  per-chunk timeouts, partial-state cleanup, and the same again for the response.

**That machinery is exactly what TCP already provides.** "Stream it in chunks over a
dedicated connection with backpressure" *is* an HTTP forward. RPC is the right tool
for small control-plane messages, the wrong tool for moving the data plane.

## Streaming HTTP forward (the proposed direction)

`Finch.request` buffers, but Finch does **not** require the full body. Both directions
can stream:

- **Request body:** `Finch.build(method, url, headers, {:stream, enumerable})` — Finch
  pulls chunks from the enumerable and writes them to the socket (chunked
  transfer-encoding). `prepare_headers/1` already strips `content-length`, so this is
  consistent.
- **Response body:** `Finch.stream/5` instead of `Finch.request/2` — yields
  `{:status, _}`, `{:headers, _}`, `{:data, chunk}` events; write each chunk to the
  client with `send_chunked/2` + `chunk/2`. `response.body` never materializes.

### The incoming body never fully buffers either

"Receiving the request" is **not atomic**. HTTP is headers-first (enough to route),
then the body streams in over many packets. `read_body(read_length: 1MB)` pulls only
what has arrived; you forward it and discard it. TCP backpressure means the client
*cannot* outrun your drain rate. The 20MB flows *through* the primary like water
through a pipe — the pipe never contains all 20 liters. The current code holds 20MB
**only because it chooses to accumulate** (`acc_body <> partial_body`).

### Sketch (local forward, streaming both ways)

```elixir
@chunk_size 1_000_000

defp forward_request(conn, target_url) do
  full_url = build_target_url(target_url, conn.request_path, conn.query_string)
  headers  = prepare_headers(conn)
  method   = String.upcase(conn.method)

  finch_request =
    Finch.build(method, full_url, headers, {:stream, request_body_stream(conn)})

  Finch.stream(finch_request, ElixirGateway.Finch, {conn, nil}, fn
    {:status, status}, {conn, _} ->
      {conn, status}

    {:headers, resp_headers}, {_conn, status} ->
      conn = Process.get(:proxy_conn)            # body fully drained by now
      conn = conn |> put_response_headers(resp_headers) |> send_chunked(status)
      {conn, status}

    {:data, data}, {conn, status} ->
      {:ok, conn} = chunk(conn, data)
      {conn, status}
  end, receive_timeout: 40_000)
end

defp request_body_stream(conn) do
  Stream.resource(
    fn -> conn end,
    fn
      {:done, _conn} -> {:halt, :done}
      conn ->
        case read_body(conn, length: @chunk_size, read_length: @chunk_size, read_timeout: 15_000) do
          {:ok, chunk, conn}   -> Process.put(:proxy_conn, conn); {[chunk], {:done, conn}}
          {:more, chunk, conn} -> Process.put(:proxy_conn, conn); {[chunk], conn}
          {:error, _}          -> {:halt, :done}
        end
    end,
    fn _ -> :ok end
  )
end
```

Peak memory per request drops from ~20MB (+ serialization copy) to ~one chunk per
direction.

### The one wart: threading the conn

`Stream.resource` swallows the conn updates from each `read_body` in its accumulator,
but `send_chunked` needs a conn that knows the body was consumed. The
`Process.put(:proxy_conn, ...)` / `Process.get(:proxy_conn)` stash works because the
body is fully drained before the `{:headers}` event fires — i.e. it relies on the
backend **not** replying mid-upload (no full duplex). **Our backends are
request/response, so this assumption holds for us.** The cleaner-but-more-code
alternative is to drive Mint directly in a push loop (read chunk →
`Mint.HTTP.stream_request_body` → read response events), keeping a single explicit
conn and no process-dictionary trick.

## Unifying the remote path: the secondary is just another upstream

The remote branch can stop being an RPC special case. Since the secondary already
runs the full gateway, the primary can HTTP-forward to it and let it resolve its own
backend off the preserved `Host` header:

```elixir
{:remote, node} ->
  target_url = node_base_url(node)   # e.g. "https://cloud-a.internal:4000"
  forward_request(conn, target_url)  # same streaming forward, no RPC
```

Two things that must be added (RPC got them for free):

1. **Loop prevention.** The RPC path called Finch directly from `handle_rpc`,
   bypassing the pipeline. An HTTP forward runs the secondary's *whole* pipeline,
   including `LoadDistributionRouter`, which could forward *again* → ping-pong. Add a
   marker header on the inner hop:

   ```elixir
   # primary: [{"x-gw-forwarded", "1"} | prepare_headers(conn)]
   # secondary LoadDistributionRouter:
   if get_req_header(conn, "x-gw-forwarded") != [],
     do: assign(conn, :target_node, :local),
     else: route_with_load_distribution(conn)
   ```

2. **Node-to-node addressing / TLS.** RPC rode the established distribution channel;
   HTTP needs the secondary reachable at a URL. Over HTTPS the secondary presents a
   cert for the *domain*, not its IP, so set SNI/Host to a domain it has a synced cert
   for, run an internal plaintext listener on a trusted network, or skip verification
   for the internal hop.

## WebSockets: same architecture, different tool

The "remote node = upstream" principle extends to WebSockets, but **Finch cannot
proxy WS** (it is request/response). Reuse `EnhancedGunWebSocketHandler` instead and
point its target at the secondary's WS endpoint:

```
client ──WS──> primary (Gun handler) ──WS──> secondary (Gun handler) ──WS──> backend
```

Gun is built for bidirectional frame relay, so the full duplex of WS is fine.

**Caveat — the payoff is smaller.** DNS pins every WS connection to the primary, so
the primary holds the socket and relays every frame *regardless*. You only offload the
backend-side connection to the secondary, not the per-frame relay. So chaining WS
across nodes is mostly about **session affinity** (routing a WS to the node that owns
the session), not load offload — unlike HTTP, where the secondary does the real
backend round-trip.

## Summary

| Mechanism | Memory | Channel | Duplex | Routing granularity |
|---|---|---|---|---|
| RPC (current) | Full buffer ×2 (raw + term) | Erlang distribution (shared w/ heartbeats) | n/a | Full (re-resolved on secondary) |
| Chunked RPC | One chunk | Still distribution; must hand-roll backpressure | n/a | Full |
| **Streaming HTTP (L7)** | **One chunk/dir** | **Dedicated socket** | Half (fine for us) | Full (Host-based on secondary) |
| L4 SNI passthrough | One chunk | Dedicated socket | Full | SNI + IP only (no cookie affinity) |

**Thesis:** the secondary is not a special RPC target, it is just another upstream the
gateway already knows how to proxy. RPC stays for the control plane (routing
decisions, cert sync, weights); the data plane wants a socket.

**Reminder of why none of this is urgent:** rate limiting and bot blocking stay
correct with node-local ETS *because* of this same single-ingress topology — only the
primary sees traffic, and during failover the ~1 minute DNS propagation means a
secondary promoted to primary starts with a clean counter anyway. The forwarding
mechanism is a data-plane efficiency question (memory + cluster stability under large
transfers), not a correctness one.
