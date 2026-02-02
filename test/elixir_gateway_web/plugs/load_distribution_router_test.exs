defmodule ElixirGatewayWeb.Plugs.LoadDistributionRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias ElixirGatewayWeb.Plugs.LoadDistributionRouter
  alias ElixirGateway.Cluster.{ConnectionRegistry, LoadDistributor}

  setup do
    # Save original config
    original_config = Application.get_env(:elixirgateway, :cluster)

    # Set up test configuration with load distribution enabled
    test_config = [
      enabled: true,
      secret: "test-secret",
      node_name: "test-node",
      peers: [],
      load_distribution: [
        enabled: true,
        node_weight: 70,
        min_requests_threshold: 20,
        window_seconds: 60
      ]
    ]

    Application.put_env(:elixirgateway, :cluster, test_config)

    # Start required processes
    {:ok, _registry_pid} = start_supervised(ConnectionRegistry)
    {:ok, _distributor_pid} = start_supervised(LoadDistributor)

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end
    end)

    :ok
  end

  describe "call/2 with load distribution enabled" do
    test "assigns :local for new session below threshold" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == :local
    end

    test "assigns :local for existing local session" do
      # First request creates the session
      conn1 =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "test-session-123")

      conn1 = LoadDistributionRouter.call(conn1, [])
      assert conn1.assigns[:target_node] == :local

      # Second request with same session should also be local
      conn2 =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "test-session-123")

      conn2 = LoadDistributionRouter.call(conn2, [])
      assert conn2.assigns[:target_node] == :local
    end

    test "assigns {:remote, node} for existing remote session" do
      # Manually register a session on a fake remote node
      # Note: IP must be a string since get_client_ip converts it with :inet.ntoa
      key = {"127.0.0.1", "remote-session-456"}
      remote_node = :"fake-remote@localhost"

      # Directly insert into ETS to simulate remote session
      :ets.insert(
        :elixirgateway_sticky_sessions,
        {key, remote_node, System.system_time(:millisecond)}
      )

      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "remote-session-456")

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == {:remote, remote_node}
    end

    test "routes new session when above threshold" do
      # Record enough requests to exceed threshold
      for _ <- 1..25 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 2})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "new-session-above-threshold")

      conn = LoadDistributionRouter.call(conn, [])

      # Since we only have primary node, should still be :local
      assert conn.assigns[:target_node] == :local
    end
  end

  describe "call/2 with load distribution disabled" do
    setup do
      # Disable load distribution
      cluster_config = Application.get_env(:elixirgateway, :cluster)
      disabled_config = put_in(cluster_config[:load_distribution][:enabled], false)
      Application.put_env(:elixirgateway, :cluster, disabled_config)

      on_exit(fn ->
        # Re-enable for other tests
        Application.put_env(:elixirgateway, :cluster, cluster_config)
      end)

      :ok
    end

    test "always assigns :local when load distribution is disabled" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == :local
    end
  end

  describe "session registration" do
    test "registers new session on local node" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 3})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "registration-test-123")

      _conn = LoadDistributionRouter.call(conn, [])

      # Verify session was registered
      conn2 =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 3})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "registration-test-123")

      result = ConnectionRegistry.get_node(conn2)
      assert result == :local
    end
  end

  describe "edge cases" do
    test "handles connection without session ID" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 4})
        |> Plug.Conn.fetch_cookies()

      conn = LoadDistributionRouter.call(conn, [])

      # Should assign to local (IP-only affinity)
      assert conn.assigns[:target_node] == :local
    end

    test "handles WebSocket connections" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 5})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("sec-websocket-key", "websocket-key-123")

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == :local
    end
  end
end
