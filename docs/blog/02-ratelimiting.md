Hello everyone! I'm back with the second part of this series! It has been a little while, but better late than never. If you haven't read the [first part](https://gonzalo-leon.site/blog/en/articles/part-1-creating-a-distributed-api-gateway-with-elixir) I suggest that you do so, since we will iterate on top of the previous work. Today we are going to talk about rate limiting and blocking bots. 

## Rate limiting
Before starting with the implementation I would like to discuss why we need rate limiting, and what are the options.

### Why rate limiting
Imagine you have a service behind the gateway that allows uploading pictures of cats. Maybe each picture can be at most 20MB which is what we support now. This service runs a small ML model to identify the image contains an actual cat. This processing consumes a lot of compute and if you have it hosted in a cloud provider it can be expensive too. 

Now imagine a bad hearted person decides to make you poor and creates a script to send a picture of exactly 20MB each millisecond. You will end up with millions of images processed each minute. You can imagine the aws finances team smiling... 

Aside from this type of exploits there are  other problems that can be fixed with a rate limit, here are some (Although not all): 
 - **URL Crawling**: there are thousands of bots trying to find exposed urls that might contain sensitive information. These bots can produce an enormous quantity of requests.
 - **DOS attacks**. These attacks bombard an endpoint to make the server incapable of answering real requests, effectively denying the service. The distributed DOS attacks (DDOS) are harder to prevent with a simple rate limit but they for sure can be softened with this.
- **Bruteforce Attacks**: an attacker might try to reach a login endpoint trying to bruteforce a password or similar by sending millions of requests.

### Implementing it

In the elixir ecosystem we have a library that specializes in rate limiting: [Hammer](https://hammer.hexdocs.pm/readme.html). We will go ahead and add it to our deps: 
```elixir
def deps do
  [
    {:hammer, "~> 7.0"}
  ]
end
```
And run `mix deps.get` to install it. Now we need to properly configure it. Hammer has some backends available for us to chose from. The backends is basically where we are storing the state like Redis. But in our case we will go with the simplest approach, at least for the moment, an ETS table. To select it, we need to create a small module: 
```elixir
defmodule ElixirGateway.RateLimit do
  use Hammer, backend: :ets
end
```
> Note: An ETS table is a mechanism erlang provides to store data in memory in tables, these are really fast and reliable. [More info](https://www.erlang.org/doc/apps/stdlib/ets.html)

Don't forget to add it to the supervision tree in `application.ex`:
```elixir
children = 
   [
     # Rest of your processes
     ElixirGateway.RateLimit,
     # Some other processes
   ]
```

Now, we will create another plug, similar to what we did in Part 1, this plug will increase the count of the rate limit and reject the requests that are over the limit. 

```elixir
  defmodule MyGateway.Plugs.RateLimiter do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      ip = format_ip(conn.remote_ip)

      case MyGateway.RateLimit.hit("gateway:#{ip}", :timer.minutes(1), 100) do
        {:allow, _count} ->
          conn

        {:deny, _retry_after} ->
          conn
          |> send_resp(429, "Too Many Requests")
          |> halt()
      end
    end

    defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  end
```
> The 429 status literally means `Too many requests`. [More info](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/429)

This is the most basic rate limiter we can have. It checks the IP of the caller and calls the Hammer bucket `gateway:<ip>`. The bucket will return `:allow` if there are still requests in the minute or `:deny` if they are too many. 

### Hardening
Obviously blocking based on the IP is the simplest but not the best option. Let's see the problems we will have:
 - Most Internet Providers use [CG-NAT](https://en.wikipedia.org/wiki/Carrier-grade_NAT) which means that several houses share a public IP, it would be weird if you could not watch YouTube because your neighbour tried to watch 150 videos in a minute.
- Some attackers might have multiple and distributed servers to bombard you with requests, each in a different IP.
- If you are behind a proxy like CloudFlare, this will make all requests share the same bucket, effectively making the limit useless. 

So how do we fix that? We have to do some modifications, first I would suggest to use 2 different buckets. One per user and another per IP. This way we can make the ip rate limit bigger to detect big attacks, and the user limit smaller to prevent abuse from registered users. 

This sounds like the ideal solution, but there is a huge problem: Identifying individual users. To do this there are a thousand things we can do like fingerprinting, requiring an api key or a mix of multiple things. In my case I found the easiest way is to hash the authorization header or get the phoenix session cookie. 

```elixir 
defp get_user_identifier(conn, ip_address) do
  cond do
    auth_header = get_req_header(conn, "authorization") |> List.first() ->
      hash(auth_header)

    session_id = get_session_id(conn) ->
      session_id

    true ->
      ip_address
  end
end

defp get_session_id(conn) do
  Enum.find_value(conn.cookies, fn {name, value} ->
    if String.ends_with?(name, "_session"), do: hash(value)
  end)
end

defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16()
```
And our call function will then be: 

```elixir
def call(conn, _opts) do
  ip = format_ip(conn.remote_ip)
  user = get_user_identifier(conn, ip)
  with {:allow, _count} <- MyGateway.RateLimit.hit("gateway:#{user}", :timer.minutes(1), 100),
       {:allow, _count} <- MyGateway.RateLimit.hit("gateway:ip:#{ip}", :timer.minutes(1), 300) do
    conn
  else
    {:deny, _retry_after} ->
      conn
      |> send_resp(429, "Too Many Requests")
      |> halt()
  end
end
```
Great! now single users have 100 requests per minute and the IPs have 300. 

What other things can we do to make it better? 
- Return a header stating the number of requests per each bucket and one for the remaining
```elixir
    conn
        |> put_resp_header("x-ratelimit-user-limit", to_string(user_requests_per_minute))
        |> put_resp_header(
          "x-ratelimit-user-remaining",
          to_string(user_requests_per_minute - user_count)
        )
        |> put_resp_header("x-ratelimit-ip-limit", to_string(ip_requests_per_minute))
        |> put_resp_header(
          "x-ratelimit-ip-remaining",
          to_string(ip_requests_per_minute - ip_count)
        )
```
- Making the limits configurable via App config or env variables
```elixir
def init(opts) do
    rate_limit_config = Application.get_env(:elixirgateway, :gateway)[:rate_limit] || []
    user_requests_per_minute = Keyword.get(rate_limit_config, :user_requests_per_minute, 100)
    ip_requests_per_minute = Keyword.get(rate_limit_config, :ip_requests_per_minute, 500)

    [rate_limit_config: {user_requests_per_minute, ip_requests_per_minute}] ++ opts
  end
```
- Supporting proxies. In the case of CloudFlare we just need the [list of IPs they use](https://www.cloudflare.com/ips/) and when we detect is one of those, we need to check the header `cf-connecting-ip` which shows the correct ip we should rate limit.
```elixir
defp get_ip_address(conn) do
    peer_ip =
      case Map.get(conn, :peer_data) do
        %{address: ip} -> ip
        _ -> conn.remote_ip
      end

    if ElixirGateway.Cluster.DDNS.Cloudflare.proxy_ip?(peer_ip) do
      get_req_header(conn, "cf-connecting-ip") |> List.first() || format_ip(peer_ip)
    else
      format_ip(peer_ip)
    end
  end
```
- Return an error response with how long you have to wait to start requesting again
```elixir
 defp send_rate_limit_response(conn, limit, message) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> send_resp(429, Jason.encode!(%{error: message, retry_after: 60}))
    |> halt()
  end
```

I'm sure there are more things we can do, but for the sake of this blog post I think it is enough. With this protection you can even bring it to production and be sure that most attacks will easily reflect.

## Bot blocking

Rate limiting for actual users, but bot blocking tries to block malicious intent. If someone requests `/wp-admin/login`and we don't have any kind of wordpress backend behind this gateway, this means it is a crawler trying to find unprotected  admin endpoints. There is no legitimate reason for that. The right response is not a 429, we directly want to ban it with a 403.

### The pattern list

The first thing we need is a list of paths that should never appear on our app. Things like PHP files, WordPress paths, `.env`, `.git`, database admin panels. Obviously if you are serving php you want to allow those. Here are some of the ones I have.

```elixir
@suspicious_patterns [
  ~r/\.php$/i,
  ~r/\.env$/i,
  ~r/\.git/i,
  ~r/wp-admin/i,
  ~r/wp-config/i,
  ~r/phpmyadmin/i,
  ~r/adminer/i,
  ~r/shell/i,
  ~r/backdoor/i,
  ~r/webshell/i,
  # ...and more
]
```
This list is defined as a module attribute so it is compiled into the module so we don't do config lookup on every request.

### The blocklist

Since we are not storing buckets of requests we don't need Hammer here. We just need a fast in-memory store to keep track of blocked IPs, and  an ETS is perfect for that. We store an entry per IP: the timestamp at which the block expires. First we must create the table on application startup (`application.ex`):
```elixir
 @impl true
  def start(_type, _args) do
    ElixirGateway.ConfigLoader.load()
    :ets.new(:bot_blocker_ips, [:set, :public, :named_table, read_concurrency: true])
     # rest of startup
  end
```

Then we create the basic logic to read and store in that table:

```elixir
@table_name :bot_blocker_ips

defp record_violation(ip) do
  block_duration = 3600  # 1 hour
  block_until = System.system_time(:second) + block_duration
  :ets.insert(@table_name, {ip, block_until})
  Logger.warning("Bot activity detected from IP #{ip}, blocking for #{block_duration}s")
end

defp is_blocked?(ip) do
  case :ets.lookup(@table_name, ip) do
    [{^ip, block_until}] ->
      if System.system_time(:second) < block_until do
        true
      else
        :ets.delete(@table_name, ip)
        false
      end
    [] -> false
  end
end
```

We could have a process to clean up expired entries, but we for the sake of simplicity we will do it lazily when a new request comes that is expired. 

The `:read_concurrency` option is important here, many requests will be reading the table simultaneously to check if their IP is blocked, and this option optimizes ETS for that pattern.

### The plug

With those pieces in place, the plug itself is straightforward:

```elixir
def call(conn, _opts) do
  if enabled?() do
    ip = get_ip_address(conn)

    cond do
      is_blocked?(ip) ->
        block_request(conn, ip, "IP blocked due to suspicious activity")

      is_suspicious_path?(conn.request_path) ->
        record_violation(ip)
        block_request(conn, ip, "Suspicious path detected")

      true ->
        conn
    end
  else
    conn
  end
end
```

One strike and you are out. The moment a scanner hits one suspicious path, the IP gets blocked for the full duration and every subsequent request from that IP is rejected immediately.

### Pipeline order

The last thing to get right is where to place these two plugs in the pipeline. BotBlocker must come before RateLimiter:

```elixir
pipeline :gateway do
  plug ElixirGatewayWeb.Plugs.BotBlocker
  plug ElixirGatewayWeb.Plugs.RateLimiter
  # rest of the pipeline...
end
```

And with this, we will properly fence multiple possible attackers and we won't waste resources in processing their requests.

## Conclusion
We have learnt how to protect ourselves from a lot of things and we properly enforced limits in a very easy and in a straightforward way. I will sleep better knowing this protections are in place for sure. 

However the Gateway is not finished, we still have some things to do. For example: **proxying websockets**. Spoiler, it is harder than it looks. But we will see it in the next part of the series. I hope I see you again!
