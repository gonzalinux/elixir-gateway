defmodule ElixirGatewayWeb.WebSocketConnectionPoolTest do
  use ExUnit.Case, async: false

  alias ElixirGatewayWeb.WebSocketConnectionPool

  setup do
    # Connection pool is already started by the application
    # Just clean up any existing connections
    :ets.delete_all_objects(:websocket_connection_pool)

    :ok
  end

  describe "connection pool management" do
    @tag :integration
    test "creates new connections when pool is empty" do
      # Mock a local HTTP server for testing
      {:ok, _server} = start_test_server(9998)
      target_url = "ws://localhost:9998/websocket"

      # First request should create a new connection
      assert {:ok, gun_pid} = WebSocketConnectionPool.get_connection(target_url)
      assert is_pid(gun_pid)

      # Verify connection is marked as in use
      stats = WebSocketConnectionPool.get_stats()
      assert stats.total_connections == 1
      assert stats.hosts["localhost:9998"].in_use == 1
    end

    @tag :integration
    test "reuses available connections" do
      {:ok, _server} = start_test_server(9999)
      target_url = "ws://localhost:9999/websocket"

      # Get a connection
      assert {:ok, gun_pid1} = WebSocketConnectionPool.get_connection(target_url)

      # Return it to the pool
      WebSocketConnectionPool.return_connection(target_url, gun_pid1)

      # Get another connection - should reuse the same one
      assert {:ok, gun_pid2} = WebSocketConnectionPool.get_connection(target_url)
      assert gun_pid1 == gun_pid2
    end

    @tag :integration
    test "respects pool size limits" do
      # Set a small pool size for testing
      original_config = Application.get_env(:elixir_gateway, :websocket)

      Application.put_env(:elixir_gateway, :websocket,
        connection_pool: [size: 2, max_idle_time: 300_000, cleanup_interval: 60_000]
      )

      {:ok, _server} = start_test_server(10000)
      target_url = "ws://localhost:10000/websocket"

      # Get two connections (pool limit)
      assert {:ok, _gun_pid1} = WebSocketConnectionPool.get_connection(target_url)
      assert {:ok, _gun_pid2} = WebSocketConnectionPool.get_connection(target_url)

      # Third connection should fail
      assert {:error, :pool_limit_reached} = WebSocketConnectionPool.get_connection(target_url)

      # Restore original config
      if original_config do
        Application.put_env(:elixir_gateway, :websocket, original_config)
      else
        Application.delete_env(:elixir_gateway, :websocket)
      end
    end

    @tag :integration
    test "removes dead connections from pool" do
      {:ok, _server} = start_test_server(10001)
      target_url = "ws://localhost:10001/websocket"

      assert {:ok, gun_pid} = WebSocketConnectionPool.get_connection(target_url)

      # Simulate connection death
      :gun.close(gun_pid)
      # Allow time for cleanup
      Process.sleep(100)

      # Remove the connection manually (simulating the monitor)
      WebSocketConnectionPool.remove_connection(target_url, gun_pid)

      # Pool should be empty now
      stats = WebSocketConnectionPool.get_stats()
      assert stats.total_connections == 0
    end

    @tag :integration
    test "tracks connection statistics correctly" do
      {:ok, _server} = start_test_server(10002)
      target_url = "ws://localhost:10002/websocket"

      # Initially empty
      stats = WebSocketConnectionPool.get_stats()
      assert stats.total_connections == 0

      # Get connection
      assert {:ok, gun_pid} = WebSocketConnectionPool.get_connection(target_url)

      stats = WebSocketConnectionPool.get_stats()
      assert stats.total_connections == 1
      assert stats.hosts["localhost:10002"].total == 1
      assert stats.hosts["localhost:10002"].in_use == 1
      assert stats.hosts["localhost:10002"].available == 0

      # Return connection
      WebSocketConnectionPool.return_connection(target_url, gun_pid)

      stats = WebSocketConnectionPool.get_stats()
      assert stats.total_connections == 1
      assert stats.hosts["localhost:10002"].in_use == 0
      assert stats.hosts["localhost:10002"].available == 1
    end
  end

  # Helper function to start a simple HTTP server for testing
  defp start_test_server(port) do
    # This is a minimal server just for connection testing
    # In a real test environment, you might use Bypass or similar
    {:ok,
     :ranch.start_listener(
       String.to_atom("test_server_#{port}"),
       :ranch_tcp,
       %{port: port},
       :cowboy_clear,
       %{env: %{dispatch: []}}
     )}
  rescue
    # If ranch/cowboy aren't available, create a simple TCP server
    _ ->
      {:ok, listen_socket} =
        :gen_tcp.listen(port, [:binary, packet: :http_bin, active: false, reuseaddr: true])

      {:ok, listen_socket}
  end
end
