# Introduction
First of all the repo is public and is in constant development: https://github.com/gonzalinux/elixir-gateway, with that out of the way let's start the series of articles about how I built this Elixir Gateway.

### What is an Api-Gateway?
It is basically the **door to enter your services**. It creates a **single point of access** to all the APIs you want to expose to the internet, this allows grouping things like rate limiting, ssl certificates generation, routing and filtering requests... And it is specially useful when you want several domains to target a single IP which is my case.

### Do I need to build an api gateway?
The short answer is **probably no**. Every single cloud provider already has a much better api gateway than a single person could even build alone (that's why they charge for it). And even if you don't want to use those, there are multiple open source alternatives like the always reliable **nginx**.
However, building it has been a great **learning opportunity** for me and I managed to get some unique features working for my specific case. And in most cases we don't need the performance and scaling of Google. Although mine works pretty good...

# Starting
### Tech stack
I selected **Elixir** because it is my favourite programming language, but even if it wasn't it is the perfect match for this use case. Elixir shines in managing thousands of connections at the same time thanks to the **BEAM virtual machine**. Basically every instruction is processed concurrently in a way that it is impossible for a process to block any other process. On top of that, it has access to **Erlang's distributed properties**, allowing seamless communication via RPC with other nodes.

**Phoenix** is a framework for Elixir that makes it very easy to create performant fullstack applications. For this project, we will use it to handle the routes and server configuration. Looking back, I could have omitted using Phoenix since we are not using most of the things it offers, but I already had experience with it and it provides a lot: endpoint, ssl, body parsing, sessions... The http server I used was **Bandit**, which is an Elixir native server with active development and supports HTTP/2.

**Finch** is a very efficient http client. It creates pools for each endpoint visited in a way that repeated calls to those endpoints reuse already existing and configured http clients. This makes it extremely memory efficient and also quite fast. There is another library built on top of Finch called Req, with a really nice user interface and good defaults, but in this case we don't want defaults like retries (could send double posts), automatic json decoding (we will pass the request raw, no need to deserialize), compression handling (no need to decompress to then compress)...

### Set up
To start a new phoenix project we just have to install elixir, erlang and phoenix. The easiest way is running this command extracted from [official phoenix docs](https://hexdocs.pm/phoenix/up_and_running.html):
```bash
curl https://new.phoenixframework.org/myapp | sh
```
Then we have to create the project folder:
```bash
mix phx.new elixir_gateway --no-ecto --no-assets --no-html --adapter bandit
```
Here we say no ecto because we don't need a database, no assets because we won't have any static file to serve, no html because we won't have a frontend. And finally adapter bandit because it is the http server we chose for this.

### Plugs
Phoenix is based on **Plugs**, they are kind of like middleware that establishes steps on handling an active connection. For example if you wanted to implement authorization in a server, you would have a plug before your handler to check if the authorization header was correctly provided, and this plug could modify the connection by adding that user identification via `assign()` or **halt** the connection returning a 401 before even reaching the handler. For more information, each connection has an `conn.assigns` object, and the plugs can either read from them or modify it. This way the previous plugin can pass data forward.

### Router
Phoenix automatically creates a `router.ex` file where we can describe API paths along with **pipelines of plugs**. In the previous example you would put the Plug to validate auth in the pipeline `:protected_routes`. In our case, the current setup contains a lot of plugs, each doing a different but important thing:
```elixir
 pipeline :gateway do
    plug(ElixirGatewayWeb.Plugs.BotBlocker)
    plug(ElixirGatewayWeb.Plugs.RateLimiter)
    plug(ElixirGatewayWeb.Plugs.WebSocketUpgradePlug)
    plug(ElixirGatewayWeb.Plugs.DomainRouter)
    plug(ElixirGatewayWeb.Plugs.HttpsRedirectPlug)
    plug(ElixirGatewayWeb.Plugs.LoadDistributionRouter)
    plug(ElixirGatewayWeb.Plugs.RequestForwarder)
  end
...
  scope "/", ElixirGatewayWeb do
    pipe_through(:gateway)
    match(:*, "/*path", GatewayController, :proxy)
  end
```
In this first article we will only see `DomainRouter` and `RequestForwarder` which are the ones that actually select the destination of the proxy.

### Config
The gateway needs to know which domain maps to which backend service. This is configured via a `gateway.yaml` file. Each entry has a name, a target URL, and a list of domains that should route to it:
```yaml
services:
  myapi:
    target: http://192.168.1.10:8080
    domains:
      - api.example.com
      - "*.api.example.com"
    ssl: true

  default:
    target: http://localhost:8000
    domains:
      - default
    ssl: false
```

At startup the config loader reads this file and builds a **flat map** of `domain => target_url` that the rest of the application uses. If you prefer not to use a file, because you are using a container or deploying somewhere weird, you can set the `GATEWAY_SERVICES` environment variable with the same information in a compact format:
```bash
GATEWAY_SERVICES="api.example.com=>http://192.168.1.10:8080;default=>http://localhost:8000"
```

The special `default` domain acts as a **catch-all** for any request that doesn't match a more specific entry. This is the entire routing table, in my case I didn't need advanced routing like path matchers or so.

### DomainRouter
This plug reads the host header and decides which destination URL the request should be proxied to.
```elixir
defmodule ElixirGatewayWeb.Plugs.DomainRouter do
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host(conn)

    case resolve_service(host) do
      nil ->
        Logger.warning("No service configured for host: #{host}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Service not found for host: #{host}"}))
        |> halt()

      target_url ->
        conn
        |> assign(:target_url, target_url)
        |> assign(:original_host, host)
    end
  end

  def resolve_service(host) do
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}
    Map.get(services, host) ||
      if(host != "default", do: Map.get(services, "default_any"))
  end

  defp get_host(conn) do
    if conn.host do
      conn.host
    else
      case get_req_header(conn, "host") do
        [host | _] ->
          # Remove port if present
          host
          |> String.split(":")
          |> List.first()

        [] ->
          "default"
      end
    end
  end
end
```
> **Note:** this is a simplified version of the DomainRouter. The current complete implementation also includes wildcard matching and forcing SSL.

As you can see the only thing it does is extracting the domain, looking for it in the configured domains, if it can't find it and there is no default configured it will **halt** the execution with a 404. If it exists, it uses `assign()` to **pass the destination to the next plugs**.

### Request Forwarder
This is where the actual proxying happens. Once `DomainRouter` has assigned the target URL to `conn.assigns[:target_url]`, this plug picks it up, builds a Finch request, fires it, and sends the response back to the client.

The core of it looks like this:
```elixir
defp forward_request(conn, target_url) do
  full_url = build_target_url(target_url, conn.request_path, conn.query_string)

  headers = prepare_headers(conn)
  body = get_request_body(conn)

  finch_request = Finch.build(conn.method, full_url, headers, body)

  case Finch.request(finch_request, ElixirGateway.Finch,
         receive_timeout: 40_000,
         request_timeout: 40_000
       ) do
    {:ok, response} ->
      conn
      |> put_response_headers(response.headers)
      |> send_resp(response.status, response.body)
      |> halt()

    {:error, _reason} ->
      conn
      |> send_resp(502, Jason.encode!(%{error: "Service unavailable"}))
      |> halt()
  end
end
```

Seems really simple, but there are two important ideas here.

**Header filtering**

You can't just forward all headers blindly. HTTP has a concept of [hop-by-hop headers](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers#hop-by-hop_headers): headers that are only meaningful between two directly connected parties and **should not be forwarded further**. Things like `connection`, `transfer-encoding`, and `keep-alive`. If you forward these the backend will get confused.

We also strip `content-length` and let Finch recalculate it, and we **replace the `host` header** with the original hostname so the backend knows which domain was requested. It is important that we manually add the Host header since by default Finch will add the service's raw ip.
```elixir
defp prepare_headers(conn) do
  excluded = MapSet.new(["connection", "keep-alive", "transfer-encoding",
                         "upgrade", "host", "content-length", ...])

  filtered = Enum.reject(conn.req_headers, fn {name, _} ->
    MapSet.member?(excluded, String.downcase(name))
  end)

  [{"host", conn.assigns[:original_host]} | filtered]
end
```

**Body reading**

This is the trickiest part. The request body in HTTP is a **stream**, meaning that once read, the stream is closed and you cannot read it again. By default, Phoenix includes a Plug called `Plug.Parsers` that automatically consumes the body to inject the JSON object deserialized into `conn.body_params`. At the time of writing this article I realized that for this specific use case we can completely **remove the Parser plug** since we won't ever need to parse the body. We will always forward the raw bytes as they are, so we remove the `Plug.Parsers` config in `endpoint.ex`.

```diff
-  plug Plug.Parsers,
-    parsers: [:urlencoded, :multipart, :json],
-    pass: ["*/*"],
-    json_decoder: Phoenix.json_library()
```

Now to actually read and forward the body, we will just read it as a binary. The chunked reading exists because `Plug.Conn.read_body/2` has a size limit per call. For large files we loop until we get an `:ok` instead of `:more`, supporting uploads up to **20MB** (this limit is mine, it could be expanded or reduced arbitrarily).

```elixir
defp get_request_body(conn) do
  read_raw_body(conn)
end

defp read_raw_body(conn) do
  case Plug.Conn.read_body(conn, length: 20_000_000, read_length: 1_000_000) do
    {:ok, body, _conn} -> body
    {:more, partial, conn} -> read_remaining_body(conn, partial)
    {:error, _} -> ""
  end
end
```

This also avoids a subtle correctness issue: if you re-encode JSON through a decoder and encoder, you can subtly change the payload (key ordering, number formatting). **Forwarding raw bytes** means the backend receives exactly what the client sent.

And that's the whole first article! With these two plugs (`DomainRouter` and `RequestForwarder`) you have a **working HTTP reverse proxy**. Every other feature in the gateway (rate limiting, bot blocking, WebSocket support, clustering) is just another plug in the same pipeline. I hope you enjoyed it and let's meet again in the next article about this Elixir-Gateway!
