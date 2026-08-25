defmodule ElixirGatewayWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using Hammer.
  """

  import Plug.Conn
  require Logger

  def init(opts) do
    rate_limit_config = Application.get_env(:elixirgateway, :gateway)[:rate_limit] || []
    user_requests_per_minute = Keyword.get(rate_limit_config, :user_requests_per_minute, 100)
    ip_requests_per_minute = Keyword.get(rate_limit_config, :ip_requests_per_minute, 500)

    [rate_limit_config: {user_requests_per_minute, ip_requests_per_minute}] ++ opts
  end

  def call(conn, opts) do
    if bypass?(conn) do
      conn
    else
      do_call(conn, opts)
    end
  end

  defp bypass?(conn) do
    with token when is_binary(token) and token != "" <-
           Application.get_env(:elixirgateway, :rate_limit_bypass_token),
         [provided] <- get_req_header(conn, "x-ratelimit-bypass-token"),
         true <- Plug.Crypto.secure_compare(provided, token) do
      Logger.info("Rate limit bypassed via bypass token")
      true
    else
      _ -> false
    end
  end

  defp do_call(conn, opts) do
    {user_requests_per_minute, ip_requests_per_minute} =
      Keyword.get(opts, :rate_limit_config, {100, 500})

    conn = fetch_cookies(conn)
    ip_address = get_ip_address(conn)
    user_id = get_user_identifier(conn, ip_address)
    # Check user-based rate limit first (more restrictive)
    user_bucket = "gateway:user:#{user_id}"
    ip_bucket = "gateway:ip:#{ip_address}"

    case check_rate_limits(
           user_bucket,
           ip_bucket,
           user_requests_per_minute,
           ip_requests_per_minute
         ) do
      {:allow, user_count, ip_count} ->
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

      {:deny, :user, _count} ->
        Logger.warning("User rate limit exceeded for user: #{user_id}")

        :telemetry.execute([:elixirgateway, :rate_limit, :exceeded], %{count: 1}, %{
          user_type: "user"
        })

        send_rate_limit_response(conn, user_requests_per_minute, "User rate limit exceeded")

      {:deny, :ip, _count} ->
        Logger.warning("IP rate limit exceeded for IP: #{ip_address}")

        :telemetry.execute([:elixirgateway, :rate_limit, :exceeded], %{count: 1}, %{
          user_type: "ip"
        })

        send_rate_limit_response(conn, ip_requests_per_minute, "IP rate limit exceeded")
    end
  end

  defp check_rate_limits(user_bucket, ip_bucket, user_limit, ip_limit) do
    case ElixirGateway.RateLimit.hit(user_bucket, 60_000, user_limit) do
      {:allow, user_count} ->
        case ElixirGateway.RateLimit.hit(ip_bucket, 60_000, ip_limit) do
          {:allow, ip_count} ->
            {:allow, user_count, ip_count}

          {:deny, _retry_after} ->
            {:deny, :ip, 0}
        end

      {:deny, _retry_after} ->
        {:deny, :user, 0}
    end
  end

  defp send_rate_limit_response(conn, limit, message) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> send_resp(429, Jason.encode!(%{error: message, retry_after: 60}))
    |> halt()
  end

  defp get_user_identifier(conn, ip_address) do
    cond do
      auth_header = get_req_header(conn, "authorization") |> List.first() ->
        extract_user_from_auth(auth_header)

      session_id = get_session_id(conn) ->
        session_id

      true ->
        ip_address
    end
  end

  defp extract_user_from_auth(header), do: hash(header)

  defp get_session_id(conn) do
    Enum.find_value(conn.cookies, fn {name, value} ->
      if String.ends_with?(name, "_session"), do: hash(value)
    end)
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16()

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

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(_), do: "unknown"
end
