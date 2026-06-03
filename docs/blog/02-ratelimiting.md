Hello everyone! I'm back with the second part of this series! It has been a little while, but better late than never. If you haven't read the [first part](https://gonzalo-leon.site/blog/en/articles/part-1-creating-a-distributed-api-gateway-with-elixir) I suggest that you do so, since we will iterate on top of the previous work. Today we are going to talk about rate limiting and blocking bots. 

# Rate limiting
Before starting with the implementation I would like to discuss why we need rate limiting, and what are the options.
### Why rate limiting
Imagine you have a service behind the gateway that allows uploading pictures of cats. Maybe each picture can be at most 20MB which is what we support now. This service runs a small ML model to identify the image contains an actual cat. This processing consumes a lot of compute and if you have it hosted in a cloud provider it can be expensive too. 

Now imagine a bad hearted person decides to make you poor and creates a script to send a picture of exactly 20MB each millisecond. You will end up with millions of images processed each minute. You can imagine the aws finances team smiling... 

Aside from this type of exploits there are  other problems that can be fixed with a rate limit, here are some (Although not all): 
 - **URL Crawling**: there are thousand of bots trying to find exposed urls that might contain sensitive information. This bots can produce an enormous quantity of requests.
 - **DOS attacks**. This attacks bombard an endpoint to make the server incapable of answering real requests, effectivelly denying the service. The distributed DOS attacks (DDOS) are harder to prevent with a simple rate limit but they for sure can be softened with this.
- **Bruteforce Attacks**: an atacker might try to reach a login endpoint trying to bruteforce a password or similar by sending millions of requests.

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

Now, we will create another plug, similar to what we did in Part 1, this plug will increase the count of the rate limit and reject the requests that are over the limit. 

```elixir
defmodule ElixirGatewayWeb.Plugs.RateLimiter do
import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
  
  end

end
```
