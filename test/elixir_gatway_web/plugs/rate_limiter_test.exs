defmodule ElixirGatewayWeb.Plugs.RateLimiterTest do
  # Hammer uses ETS, so can't be async
  use ElixirGatewayWeb.ConnCase, async: false

  alias ElixirGatewayWeb.Plugs.RateLimiter

  setup do
    # Set up test configuration
    original_config = Application.get_env(:elixirgateway, :gateway)

    Application.put_env(:elixirgateway, :gateway,
      rate_limit: [
        # Higher limit for more predictable testing
        user_requests_per_minute: 100,
        ip_requests_per_minute: 500,
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

    :ok
  end

  describe "rate limiting by X-User-ID header" do
    test "allows requests under the limit", %{conn: conn} do
      # Use unique user ID to avoid conflicts with other tests
      user_id = "user123_#{System.unique_integer([:positive])}"

      conn =
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "blocks requests over the limit", %{conn: conn} do
      user_id = "user456_#{System.unique_integer([:positive])}"

      # Make requests up to the limit
      Enum.each(1..100, fn _ ->
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])
      end)

      # Next request should be blocked
      conn =
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "Rate limit exceeded"
      assert response["retry_after"] == 60
    end

    test "tracks different users separately", %{conn: conn} do
      user1_id = "user1_#{System.unique_integer([:positive])}"
      user2_id = "user2_#{System.unique_integer([:positive])}"

      # User 1 makes requests
      Enum.each(1..100, fn _ ->
        conn
        |> put_req_header("x-user-id", user1_id)
        |> RateLimiter.call([])
      end)

      # User 2 should still be able to make requests
      conn =
        conn
        |> put_req_header("x-user-id", user2_id)
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end
  end

  describe "rate limiting by Authorization header" do
    test "uses hashed authorization header as identifier", %{conn: conn} do
      auth_header = "Bearer token123_#{System.unique_integer([:positive])}"

      conn =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "same authorization header gets same rate limit bucket", %{conn: conn} do
      auth_header = "Bearer same-token_#{System.unique_integer([:positive])}"

      # First request
      conn1 =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      # Second request with same auth header
      conn2 =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      refute conn1.halted
      refute conn2.halted
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["98"]
    end

    test "different authorization headers get different buckets", %{conn: conn} do
      token1 = "Bearer token1_#{System.unique_integer([:positive])}"
      token2 = "Bearer token2_#{System.unique_integer([:positive])}"

      # Make requests with first auth header
      Enum.each(1..100, fn _ ->
        conn
        |> put_req_header("authorization", token1)
        |> RateLimiter.call([])
      end)

      # Second auth header should have separate bucket
      conn =
        conn
        |> put_req_header("authorization", token2)
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "blocks requests over the limit for authorization header", %{conn: conn} do
      auth_header = "Bearer limit-test_#{System.unique_integer([:positive])}"

      # Make requests up to the limit
      Enum.each(1..100, fn _ ->
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])
      end)

      # Next request should be blocked
      conn =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]

      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "Rate limit exceeded"
      assert response["retry_after"] == 60
    end
  end

  describe "rate limiting by IP address fallback" do
    test "uses IP address when no user headers present", %{conn: conn} do
      # Simulate unique IP address to avoid conflicts
      base = System.unique_integer([:positive])
      unique_ip = {10, 0, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      conn = RateLimiter.call(conn, [])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "same IP gets same rate limit bucket", %{conn: conn} do
      # Use unique IP to avoid conflicts with other tests
      base = System.unique_integer([:positive])
      ip = {192, 168, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}

      # First request
      conn1 =
        Map.put(conn, :peer_data, %{address: ip})
        |> RateLimiter.call([])

      # Second request from same IP
      conn2 =
        Map.put(conn, :peer_data, %{address: ip})
        |> RateLimiter.call([])

      refute conn1.halted
      refute conn2.halted
      # Verify that second request has one less remaining (98 instead of 99)
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["98"]
    end

    test "different IPs get different buckets", %{conn: conn} do
      base = System.unique_integer([:positive])
      ip1 = {172, 16, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      ip2 = {172, 16, rem(base + 100, 254) + 1, rem(div(base + 100, 256), 254) + 1}

      # First request from IP1
      conn1 =
        Map.put(conn, :peer_data, %{address: ip1})
        |> RateLimiter.call([])

      # First request from IP2
      conn2 =
        Map.put(conn, :peer_data, %{address: ip2})
        |> RateLimiter.call([])

      # Both should succeed and have separate buckets (both showing 4 remaining)
      refute conn1.halted
      refute conn2.halted
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["99"]
    end

    test "handles unknown peer data gracefully", %{conn: conn} do
      # Simulate unknown peer data by removing peer_data
      conn = Map.put(conn, :peer_data, nil)

      conn = RateLimiter.call(conn, [])

      refute conn.halted

      # With request hashing, the request gets a consistent bucket based on request characteristics
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]

      remaining =
        get_resp_header(conn, "x-ratelimit-remaining") |> List.first() |> String.to_integer()

      # Should be between 0 and 99 (since one request was made)
      assert remaining >= 0 and remaining <= 99
    end

    test "same request without peer data gets same bucket", %{conn: conn} do
      # Simulate unknown peer data by removing peer_data
      conn = Map.put(conn, :peer_data, nil)

      # First request
      conn1 = RateLimiter.call(conn, [])

      remaining1 =
        get_resp_header(conn1, "x-ratelimit-remaining") |> List.first() |> String.to_integer()

      # Second identical request
      conn2 = Map.put(conn, :peer_data, nil)
      conn2 = RateLimiter.call(conn2, [])

      remaining2 =
        get_resp_header(conn2, "x-ratelimit-remaining") |> List.first() |> String.to_integer()

      refute conn1.halted
      refute conn2.halted
      # Second request should have one less remaining than first
      assert remaining2 == remaining1 - 1
    end
  end

  describe "header priority" do
    test "X-User-ID takes priority over Authorization header", %{conn: conn} do
      user_id = "priority-user_#{System.unique_integer([:positive])}"
      auth_header = "Bearer should-be-ignored_#{System.unique_integer([:positive])}"

      # Request with both headers - should use X-User-ID
      conn1 =
        conn
        |> put_req_header("x-user-id", user_id)
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      # Request with just authorization header - should use different bucket
      conn2 =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      # Should have different remaining counts if using different identifiers
      refute conn1.halted
      refute conn2.halted
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["99"]
    end

    test "Authorization header takes priority over IP", %{conn: conn} do
      auth_header = "Bearer priority-token_#{System.unique_integer([:positive])}"

      # Use unique IP to avoid conflicts
      base = System.unique_integer([:positive])
      unique_ip = {10, 10, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      # Request with auth header (uses auth bucket)
      conn1 =
        conn
        |> put_req_header("authorization", auth_header)
        |> RateLimiter.call([])

      # Request without auth header (uses IP bucket)
      conn2 = RateLimiter.call(conn, [])

      # Both should succeed because they use different buckets
      refute conn1.halted
      refute conn2.halted
      # Auth bucket
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      # IP bucket
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["99"]
    end

    test "X-User-ID takes priority over IP", %{conn: conn} do
      user_id = "priority-user-ip_#{System.unique_integer([:positive])}"

      # Use unique IP to avoid conflicts
      base = System.unique_integer([:positive])
      unique_ip = {172, 20, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      # Request with X-User-ID (uses user bucket)
      conn1 =
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])

      # Request without X-User-ID (uses IP bucket)
      conn2 = RateLimiter.call(conn, [])

      # Both should succeed because they use different buckets
      refute conn1.halted
      refute conn2.halted
      # User bucket
      assert get_resp_header(conn1, "x-ratelimit-remaining") == ["99"]
      # IP bucket
      assert get_resp_header(conn2, "x-ratelimit-remaining") == ["99"]
    end
  end

  describe "edge cases" do
    test "handles empty X-User-ID header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-user-id", "")
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "handles empty Authorization header", %{conn: conn} do
      # Use unique IP to avoid conflicts
      base = System.unique_integer([:positive])
      unique_ip = {192, 169, rem(base, 254) + 1, rem(div(base, 256), 254) + 1}
      conn = Map.put(conn, :peer_data, %{address: unique_ip})

      conn =
        conn
        |> put_req_header("authorization", "")
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "handles malformed peer data", %{conn: conn} do
      conn = Map.put(conn, :peer_data, %{address: "invalid"})

      conn = RateLimiter.call(conn, [])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
    end

    test "handles missing peer data", %{conn: conn} do
      conn = Map.put(conn, :peer_data, %{})

      conn = RateLimiter.call(conn, [])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
    end
  end

  describe "custom rate limit configuration" do
    test "uses custom rate limit from configuration", %{conn: conn} do
      Application.put_env(:elixirgateway, :gateway,
        rate_limit: [
          requests_per_minute: 50
        ]
      )

      unique_user = "custom-limit-user_#{System.unique_integer([:positive])}"

      conn =
        conn
        |> put_req_header("x-user-id", unique_user)
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["50"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["49"]
    end

    test "blocks requests at custom limit", %{conn: conn} do
      Application.put_env(:elixirgateway, :gateway,
        rate_limit: [
          requests_per_minute: 5
        ]
      )

      user_id = "custom-limit-block_#{System.unique_integer([:positive])}"

      # Make requests up to the custom limit
      Enum.each(1..5, fn _ ->
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])
      end)

      # Next request should be blocked
      conn =
        conn
        |> put_req_header("x-user-id", user_id)
        |> RateLimiter.call([])

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "x-ratelimit-limit") == ["5"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]
    end
  end

  describe "configuration" do
    test "uses default rate limit when not configured", %{conn: conn} do
      Application.delete_env(:elixirgateway, :gateway)

      # Use unique user to avoid conflicts
      unique_user = "test-user_#{System.unique_integer([:positive])}"

      conn =
        conn
        |> put_req_header("x-user-id", unique_user)
        |> RateLimiter.call([])

      refute conn.halted
      # Default should be 100 requests per minute
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["99"]
    end

    test "handles missing rate_limit config section", %{conn: conn} do
      Application.put_env(:elixirgateway, :gateway, services: %{})

      conn =
        conn
        |> put_req_header("x-user-id", "test-user")
        |> RateLimiter.call([])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["100"]
    end
  end
end
