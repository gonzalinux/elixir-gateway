defmodule ElixirGatewayWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using Hammer.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    rate_limit_config = Application.get_env(:elixir_gateway, :gateway)[:rate_limit] || []
    user_requests_per_minute = Keyword.get(rate_limit_config, :user_requests_per_minute, 100)
    ip_requests_per_minute = Keyword.get(rate_limit_config, :ip_requests_per_minute, 500)

    {user_id, ip_address} = get_identifiers(conn)

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
        send_rate_limit_response(conn, user_requests_per_minute, "User rate limit exceeded")

      {:deny, :ip, _count} ->
        Logger.warning("IP rate limit exceeded for IP: #{ip_address}")
        send_rate_limit_response(conn, ip_requests_per_minute, "IP rate limit exceeded")
    end
  end

  defp check_rate_limits(user_bucket, ip_bucket, user_limit, ip_limit) do
    case Hammer.check_rate(user_bucket, 60_000, user_limit) do
      {:allow, user_count} ->
        case Hammer.check_rate(ip_bucket, 60_000, ip_limit) do
          {:allow, ip_count} ->
            {:allow, user_count, ip_count}

          {:deny, ip_count} ->
            {:deny, :ip, ip_count}
        end

      {:deny, user_count} ->
        {:deny, :user, user_count}
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

  defp get_identifiers(conn) do
    user_id = get_user_identifier(conn)
    ip_address = get_ip_address(conn)
    {user_id, ip_address}
  end

  defp get_user_identifier(conn) do
    cond do
      # Try X-User-ID header first
      user_id = get_req_header(conn, "x-user-id") |> List.first() ->
        user_id

      # Try Authorization header
      auth_header = get_req_header(conn, "authorization") |> List.first() ->
        # Extract user from JWT or basic auth - simplified for now
        :crypto.hash(:sha256, auth_header) |> Base.encode16()

      # Fall back to IP-based identifier
      true ->
        get_ip_address(conn)
    end
  end

  defp get_ip_address(conn) do
    case Map.get(conn, :peer_data) do
      %{address: {a, b, c, d}} ->
        "#{a}.#{b}.#{c}.#{d}"

      _ ->
        # Fallback to remote_ip if peer_data is not available (like in tests)
        case conn.remote_ip do
          {a, b, c, d} ->
            "#{a}.#{b}.#{c}.#{d}"

          _ ->
            # Hash the request to create a consistent identifier for unknown sources
            request_hash =
              :crypto.hash(
                :sha256,
                "#{conn.method}#{conn.request_path}#{inspect(conn.req_headers)}"
              )

            "unknown_" <> Base.encode16(request_hash, case: :lower)
        end
    end
  end
end
