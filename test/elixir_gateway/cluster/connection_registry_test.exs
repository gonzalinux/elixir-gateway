defmodule ElixirGateway.Cluster.ConnectionRegistryTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias ElixirGateway.Cluster.ConnectionRegistry
  alias Plug.Conn

  setup do
    # Store original config
    original_config = Application.get_env(:elixirgateway, :cluster)

    # Enable clustering with short TTL for testing
    Application.put_env(:elixirgateway, :cluster,
      enabled: true,
      session_ttl_minutes: 1,
      cleanup_interval_minutes: 1
    )

    # Start the ConnectionRegistry
    {:ok, pid} = start_supervised(ConnectionRegistry)

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end
    end)

    {:ok, registry: pid}
  end

  describe "get_node/1" do
    test "returns :local for first-time connection" do
      conn = build_conn("192.168.1.1", nil)

      assert :local = ConnectionRegistry.get_node(conn)
    end

    test "returns :local for existing session on same node" do
      conn = build_conn("192.168.1.1", "session123")

      # First access
      assert :local = ConnectionRegistry.get_node(conn)

      # Second access - should still be local
      assert :local = ConnectionRegistry.get_node(conn)
    end

    test "returns :not_clustered when clustering is disabled" do
      # Disable clustering
      Application.put_env(:elixirgateway, :cluster, enabled: false)

      conn = build_conn("192.168.1.1", nil)

      assert :not_clustered = ConnectionRegistry.get_node(conn)
    end

    test "creates separate sessions for different IPs" do
      conn1 = build_conn("192.168.1.1", nil)
      conn2 = build_conn("192.168.1.2", nil)

      assert :local = ConnectionRegistry.get_node(conn1)
      assert :local = ConnectionRegistry.get_node(conn2)

      # Both should be registered
      assert ConnectionRegistry.session_count() == 2
    end

    test "creates separate sessions for same IP with different session IDs" do
      conn1 = build_conn("192.168.1.1", "session1")
      conn2 = build_conn("192.168.1.1", "session2")

      assert :local = ConnectionRegistry.get_node(conn1)
      assert :local = ConnectionRegistry.get_node(conn2)

      # Both should be registered as separate sessions
      assert ConnectionRegistry.session_count() == 2
    end

    test "reuses session for same IP and session ID" do
      conn = build_conn("192.168.1.1", "session123")

      assert :local = ConnectionRegistry.get_node(conn)
      assert :local = ConnectionRegistry.get_node(conn)

      # Should only have one session
      assert ConnectionRegistry.session_count() == 1
    end
  end

  describe "register_connection/1" do
    test "registers a connection with map conn" do
      conn = build_conn("192.168.1.1", "session123")

      assert :ok = ConnectionRegistry.register_connection(conn)
      assert ConnectionRegistry.session_count() == 1
    end

    test "registers a connection with tuple key" do
      key = {"192.168.1.1", "session123"}

      assert :ok = ConnectionRegistry.register_connection(key)
      assert ConnectionRegistry.session_count() == 1
    end

    test "returns :ok when clustering is disabled" do
      Application.put_env(:elixirgateway, :cluster, enabled: false)

      conn = build_conn("192.168.1.1", nil)

      assert :ok = ConnectionRegistry.register_connection(conn)
      assert ConnectionRegistry.session_count() == 0
    end
  end

  describe "unregister_connection/1" do
    test "removes a registered session" do
      conn = build_conn("192.168.1.1", "session123")

      # Register
      ConnectionRegistry.register_connection(conn)
      assert ConnectionRegistry.session_count() == 1

      # Unregister
      ConnectionRegistry.unregister_connection(conn)
      assert ConnectionRegistry.session_count() == 0
    end

    test "unregisters with tuple key" do
      key = {"192.168.1.1", "session123"}

      # Register
      ConnectionRegistry.register_connection(key)
      assert ConnectionRegistry.session_count() == 1

      # Unregister
      ConnectionRegistry.unregister_connection(key)
      assert ConnectionRegistry.session_count() == 0
    end

    test "handles unregistering non-existent session" do
      conn = build_conn("192.168.1.1", "session123")

      # Should not error
      assert :ok = ConnectionRegistry.unregister_connection(conn)
    end
  end

  describe "session_count/0" do
    test "returns 0 when no sessions are registered" do
      assert ConnectionRegistry.session_count() == 0
    end

    test "returns correct count with multiple sessions" do
      conn1 = build_conn("192.168.1.1", "session1")
      conn2 = build_conn("192.168.1.2", "session2")
      conn3 = build_conn("192.168.1.3", "session3")

      ConnectionRegistry.register_connection(conn1)
      ConnectionRegistry.register_connection(conn2)
      ConnectionRegistry.register_connection(conn3)

      assert ConnectionRegistry.session_count() == 3
    end

    test "returns 0 when clustering is disabled" do
      Application.put_env(:elixirgateway, :cluster, enabled: false)

      assert ConnectionRegistry.session_count() == 0
    end
  end

  describe "session persistence and TTL" do
    test "sessions persist across multiple accesses" do
      conn = build_conn("192.168.1.1", "session123")

      # First access
      ConnectionRegistry.get_node(conn)

      # Wait a bit
      Process.sleep(100)

      # Second access - session should still exist
      assert :local = ConnectionRegistry.get_node(conn)
      assert ConnectionRegistry.session_count() == 1
    end

    test "updates last_access_time on each access" do
      conn = build_conn("192.168.1.1", "session123")

      # Initial registration
      ConnectionRegistry.register_connection(conn)

      # Access multiple times
      ConnectionRegistry.get_node(conn)
      Process.sleep(100)
      ConnectionRegistry.get_node(conn)
      Process.sleep(100)
      ConnectionRegistry.get_node(conn)

      # Session should still be active
      assert ConnectionRegistry.session_count() == 1
    end

    test "stale sessions are cleaned up after TTL expires" do
      # Configure very short TTL for testing
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        session_ttl_minutes: 0.001,
        cleanup_interval_minutes: 1
      )

      # Restart registry with new config
      stop_supervised(ConnectionRegistry)
      {:ok, _pid} = start_supervised(ConnectionRegistry)

      conn = build_conn("192.168.1.1", "session123")
      ConnectionRegistry.register_connection(conn)

      assert ConnectionRegistry.session_count() == 1

      # Wait for TTL to expire (60ms = 0.001 minutes)
      Process.sleep(100)

      # Trigger cleanup manually
      send(Process.whereis(ConnectionRegistry), :cleanup_sessions)
      Process.sleep(50)

      # Session should be cleaned up
      assert ConnectionRegistry.session_count() == 0
    end
  end

  describe "session identification" do
    test "uses X-Forwarded-For header for client IP" do
      conn = build_conn_with_headers([{"x-forwarded-for", "203.0.113.1, 198.51.100.1"}])

      ConnectionRegistry.get_node(conn)

      # Should use first IP from X-Forwarded-For
      assert ConnectionRegistry.session_count() == 1
    end

    test "uses X-Real-IP header when X-Forwarded-For is absent" do
      conn = build_conn_with_headers([{"x-real-ip", "203.0.113.1"}])

      ConnectionRegistry.get_node(conn)

      assert ConnectionRegistry.session_count() == 1
    end

    test "uses WebSocket key as session ID" do
      conn = build_conn_with_headers([{"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}])

      ConnectionRegistry.get_node(conn)

      assert ConnectionRegistry.session_count() == 1
    end

    test "uses session cookie as session ID" do
      conn = conn(:get, "/")
      conn = %{conn | remote_ip: {192, 168, 1, 1}}
      # Set cookie via Cookie header
      conn = Conn.put_req_header(conn, "cookie", "_elixirgateway_key=cookie_session_123")
      conn = Conn.fetch_cookies(conn)

      ConnectionRegistry.get_node(conn)

      assert ConnectionRegistry.session_count() == 1
    end

    test "uses X-Session-ID header as session ID" do
      conn = build_conn_with_headers([{"x-session-id", "custom_session_456"}])

      ConnectionRegistry.get_node(conn)

      assert ConnectionRegistry.session_count() == 1
    end
  end

  # Helper functions

  defp build_conn(ip_string, session_id) do
    ip_tuple = ip_string |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

    conn = conn(:get, "/")
    conn = %{conn | remote_ip: ip_tuple}
    conn = Conn.fetch_cookies(conn)

    if session_id do
      Conn.put_req_header(conn, "x-session-id", session_id)
    else
      conn
    end
  end

  defp build_conn_with_headers(headers) do
    conn = conn(:get, "/")
    conn = %{conn | remote_ip: {192, 168, 1, 1}}
    conn = Conn.fetch_cookies(conn)

    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Conn.put_req_header(acc, key, value)
    end)
  end
end
