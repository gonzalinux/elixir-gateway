defmodule ExgatewayWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using Hammer.
  """
  
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    rate_limit_config = Application.get_env(:exgateway, :gateway)[:rate_limit] || []
    requests_per_minute = Keyword.get(rate_limit_config, :requests_per_minute, 100)
    
    user_id = get_user_identifier(conn)
    bucket_name = "gateway:#{user_id}"
    
    case Hammer.check_rate(bucket_name, 60_000, requests_per_minute) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(requests_per_minute))
        |> put_resp_header("x-ratelimit-remaining", to_string(requests_per_minute - count))
      
      {:deny, _limit} ->
        Logger.warning("Rate limit exceeded for user: #{user_id}")
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("x-ratelimit-limit", to_string(requests_per_minute))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, Jason.encode!(%{error: "Rate limit exceeded", retry_after: 60}))
        |> halt()
    end
  end

  defp get_user_identifier(conn) do
    # Try to get user ID from various sources
    cond do
      # Try X-User-ID header first
      user_id = get_req_header(conn, "x-user-id") |> List.first() ->
        user_id
      
      # Try Authorization header
      auth_header = get_req_header(conn, "authorization") |> List.first() ->
        # Extract user from JWT or basic auth - simplified for now
        :crypto.hash(:sha256, auth_header) |> Base.encode16()
      
      # Fall back to IP address
      true ->
        case get_peer_data(conn) do
          %{address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
          _ -> "unknown"
        end
    end
  end
end