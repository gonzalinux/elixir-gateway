defmodule ElixirGatewayWeb.Plugs.DualRateLimiterTest do
  # Hammer uses ETS, so can't be async
  use ElixirGatewayWeb.ConnCase, async: false

  alias ElixirGatewayWeb.Plugs.RateLimiter

  setup do
    # Set up test configuration
    original_config = Application.get_env(:elixirgateway, :gateway)

    Application.put_env(:elixirgateway, :gateway,
      rate_limit: [
        # Low for easier testing
        user_requests_per_minute: 5,
        # Higher than user limit
        ip_requests_per_minute: 10,
        cleanup_interval: :timer.minutes(1)
      ]
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :gateway, original_config)
      else
        Application.delete_env(:elixirgateway, :gateway)
      end
    end)

    %{opts: RateLimiter.init([])}
  end

  describe "dual rate limiting (user + IP)" do
    test "allows requests under both limits", %{conn: conn, opts: opts} do
      token = "Bearer token_#{System.unique_integer([:positive])}"
      base = System.unique_integer([:positive])
      unique_ip = {10, 0, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      conn =
        conn
        |> Map.put(:peer_data, %{address: unique_ip})
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-user-limit") == ["5"]
      assert get_resp_header(conn, "x-ratelimit-user-remaining") == ["4"]
      assert get_resp_header(conn, "x-ratelimit-ip-limit") == ["10"]
      assert get_resp_header(conn, "x-ratelimit-ip-remaining") == ["9"]
    end

    test "blocks when user limit exceeded but IP limit not exceeded", %{conn: conn, opts: opts} do
      token = "Bearer token_limit_test_#{System.unique_integer([:positive])}"
      base = System.unique_integer([:positive])
      unique_ip = {10, 1, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      # Make 5 requests (user limit)
      Enum.each(1..5, fn _ ->
        conn
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)
      end)

      # 6th request should be blocked due to user limit
      conn =
        conn
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)

      assert conn.halted
      assert conn.status == 429
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "User rate limit exceeded"
    end

    test "blocks when IP limit exceeded but user limit not exceeded", %{conn: conn, opts: opts} do
      base = System.unique_integer([:positive])
      unique_ip = {10, 2, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      # Make 10 requests from same IP with different users (via distinct Bearer tokens)
      Enum.each(1..10, fn i ->
        conn
        |> put_req_header(
          "authorization",
          "Bearer token_#{i}_#{System.unique_integer([:positive])}"
        )
        |> RateLimiter.call(opts)
      end)

      # 11th request should be blocked due to IP limit
      conn =
        conn
        |> put_req_header(
          "authorization",
          "Bearer token_new_#{System.unique_integer([:positive])}"
        )
        |> RateLimiter.call(opts)

      assert conn.halted
      assert conn.status == 429
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "IP rate limit exceeded"
    end

    test "different IPs can exceed combined user requests", %{conn: conn, opts: opts} do
      token = "Bearer shared_token_#{System.unique_integer([:positive])}"
      base = System.unique_integer([:positive])

      ip1 = {10, 3, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      ip2 = {10, 3, rem(base + 100, 254) + 1, rem(div(base + 100, 256), 254) + 1}

      # User makes 5 requests from IP1 (hits user limit)
      conn1 = Map.put(conn, :peer_data, %{address: ip1})

      Enum.each(1..5, fn _ ->
        conn1
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)
      end)

      # Same user tries from IP2 - should still be blocked (user limit exceeded)
      conn2 =
        conn
        |> Map.put(:peer_data, %{address: ip2})
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)

      assert conn2.halted
      assert conn2.status == 429
      {:ok, response} = Jason.decode(conn2.resp_body)
      assert response["error"] == "User rate limit exceeded"
    end

    test "fallback to IP-only rate limiting when no user headers", %{conn: conn, opts: opts} do
      base = System.unique_integer([:positive])
      unique_ip = {10, 4, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      # Without user headers, should use IP for both user and IP buckets
      # Since user_id falls back to IP, both buckets will be the same
      # So effectively it's limited by the more restrictive limit (user: 5)

      # Make 5 requests (user limit when using IP as user_id)
      Enum.each(1..5, fn _ ->
        RateLimiter.call(conn, opts)
      end)

      # 6th request should be blocked
      conn = RateLimiter.call(conn, opts)

      assert conn.halted
      assert conn.status == 429
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "User rate limit exceeded"
    end
  end

  describe "separate bucket tracking" do
    test "user and IP buckets are tracked independently", %{conn: conn, opts: opts} do
      token = "Bearer independent_token_#{System.unique_integer([:positive])}"
      base = System.unique_integer([:positive])

      ip1 = {10, 5, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      ip2 = {10, 5, rem(base + 50, 254) + 1, rem(div(base + 50, 256), 254) + 1}

      # User makes 3 requests from IP1
      conn1 = Map.put(conn, :peer_data, %{address: ip1})

      Enum.each(1..3, fn _ ->
        conn1
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)
      end)

      # Same user makes request from IP2 - should work (different IP bucket)
      conn2 =
        conn
        |> Map.put(:peer_data, %{address: ip2})
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)

      refute conn2.halted
      # User bucket should show 1 remaining (4 total requests made by user)
      assert get_resp_header(conn2, "x-ratelimit-user-remaining") == ["1"]
      # IP2 bucket should show 9 remaining (1 request made from this IP)
      assert get_resp_header(conn2, "x-ratelimit-ip-remaining") == ["9"]
    end
  end

  describe "header responses" do
    test "includes both user and IP limit headers in responses", %{conn: conn, opts: opts} do
      token = "Bearer token_header_test_#{System.unique_integer([:positive])}"
      base = System.unique_integer([:positive])
      unique_ip = {10, 6, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      conn =
        conn
        |> Map.put(:peer_data, %{address: unique_ip})
        |> put_req_header("authorization", token)
        |> RateLimiter.call(opts)

      refute conn.halted

      # Check all expected headers are present
      assert get_resp_header(conn, "x-ratelimit-user-limit") == ["5"]
      assert get_resp_header(conn, "x-ratelimit-user-remaining") == ["4"]
      assert get_resp_header(conn, "x-ratelimit-ip-limit") == ["10"]
      assert get_resp_header(conn, "x-ratelimit-ip-remaining") == ["9"]
    end
  end
end
