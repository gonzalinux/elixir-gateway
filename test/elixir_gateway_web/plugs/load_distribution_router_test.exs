defmodule ElixirGatewayWeb.Plugs.LoadDistributionRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias ElixirGatewayWeb.Plugs.LoadDistributionRouter
  alias ElixirGateway.Cluster.{ConnectionRegistry, LoadDistributor, ServiceHealth}

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

  describe "service availability check for new sessions" do
    setup do
      original_gateway = Application.get_env(:elixirgateway, :gateway)

      Application.put_env(:elixirgateway, :gateway,
        services: %{"api.example.com" => "http://localhost:8080"}
      )

      on_exit(fn ->
        if original_gateway do
          Application.put_env(:elixirgateway, :gateway, original_gateway)
        else
          Application.delete_env(:elixirgateway, :gateway)
        end
      end)

      :ok
    end

    test "routes new session to local when service is configured locally" do
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 10, 1})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "service-check-local-1")
        |> Plug.Conn.assign(:original_host, "api.example.com")

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == :local
    end

    test "routes to local node (only node) regardless of service check" do
      # With only one node, selected_node always == node(), so no service check is made
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 10, 2})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "service-check-single-node")
        |> Plug.Conn.assign(:original_host, "unconfigured.host.com")

      conn = LoadDistributionRouter.call(conn, [])

      assert conn.assigns[:target_node] == :local
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

  describe "health failover" do
    # Each test gets its own service key and fake peers, so health rows never leak
    # between tests. Health is faked through the same casts real peers send.
    setup do
      key = "svc#{System.unique_integer([:positive])}.test"
      peer_a = :"peer_a_#{System.unique_integer([:positive])}@127.0.0.1"
      peer_b = :"peer_b_#{System.unique_integer([:positive])}@127.0.0.1"

      on_exit(fn ->
        GenServer.cast(ServiceHealth, {:peer_update, node(), [key], :ok})
        send(ServiceHealth, {:nodedown, peer_a})
        send(ServiceHealth, {:nodedown, peer_b})
        :sys.get_state(ServiceHealth)
      end)

      {:ok, key: key, peer_a: peer_a, peer_b: peer_b}
    end

    # Casts are async: the sync call returns once every earlier cast is handled
    defp mark_down(node, key) do
      GenServer.cast(ServiceHealth, {:peer_update, node, [key], :ko})
      :sys.get_state(ServiceHealth)
    end

    # Tells LoadDistributor the peer serves these keys, so node_has_service?/2 is true
    defp register_peer(peer, service_keys) do
      GenServer.cast(
        LoadDistributor,
        {:remote_node_weight, %{node: peer, weight: 30, services: service_keys}}
      )

      :sys.get_state(LoadDistributor)
    end

    defp routed(key, target) do
      conn(:get, "/test")
      |> Plug.Conn.assign(:service_key, key)
      |> Plug.Conn.assign(:target_node, target)
    end

    defp failover(conn, peers), do: LoadDistributionRouter.maybe_failover_with_health(conn, peers)

    test "keeps :local when the local service is healthy", %{key: key, peer_a: peer_a} do
      register_peer(peer_a, [key])

      assert failover(routed(key, :local), [peer_a]).assigns.target_node == :local
    end

    test "keeps a healthy remote target", %{key: key, peer_a: peer_a} do
      conn = failover(routed(key, {:remote, peer_a}), [peer_a])

      assert conn.assigns.target_node == {:remote, peer_a}
    end

    test "local down: fails over to a healthy peer that has the service",
         %{key: key, peer_a: peer_a} do
      register_peer(peer_a, [key])
      mark_down(node(), key)

      assert failover(routed(key, :local), [peer_a]).assigns.target_node == {:remote, peer_a}
    end

    test "local down: skips a peer whose service is down", %{
      key: key,
      peer_a: peer_a,
      peer_b: peer_b
    } do
      register_peer(peer_a, [key])
      register_peer(peer_b, [key])
      mark_down(node(), key)
      mark_down(peer_a, key)

      conn = failover(routed(key, :local), [peer_a, peer_b])

      assert conn.assigns.target_node == {:remote, peer_b}
    end

    test "local down: skips a peer that does not serve the service", %{
      key: key,
      peer_a: peer_a
    } do
      register_peer(peer_a, ["other.test"])
      mark_down(node(), key)

      assert failover(routed(key, :local), [peer_a]).assigns.target_node == :local
    end

    test "local down and every peer down: stays :local", %{key: key, peer_a: peer_a} do
      register_peer(peer_a, [key])
      mark_down(node(), key)
      mark_down(peer_a, key)

      assert failover(routed(key, :local), [peer_a]).assigns.target_node == :local
    end

    test "local down and no peers: stays :local", %{key: key} do
      mark_down(node(), key)

      assert failover(routed(key, :local), []).assigns.target_node == :local
    end

    test "pinned peer down: falls back to the healthy local node", %{key: key, peer_a: peer_a} do
      register_peer(peer_a, [key])
      mark_down(peer_a, key)

      assert failover(routed(key, {:remote, peer_a}), [peer_a]).assigns.target_node == :local
    end

    test "pinned peer down and local down: moves to another healthy peer", %{
      key: key,
      peer_a: peer_a,
      peer_b: peer_b
    } do
      register_peer(peer_a, [key])
      register_peer(peer_b, [key])
      mark_down(peer_a, key)
      mark_down(node(), key)

      conn = failover(routed(key, {:remote, peer_a}), [peer_a, peer_b])

      assert conn.assigns.target_node == {:remote, peer_b}
    end

    test "pinned peer down and everything else down: stays :local", %{
      key: key,
      peer_a: peer_a
    } do
      register_peer(peer_a, [key])
      mark_down(peer_a, key)
      mark_down(node(), key)

      assert failover(routed(key, {:remote, peer_a}), [peer_a]).assigns.target_node == :local
    end

    test "only the failing service fails over", %{key: key, peer_a: peer_a} do
      other_key = "other_#{key}"
      register_peer(peer_a, [key, other_key])
      mark_down(node(), key)

      assert failover(routed(key, :local), [peer_a]).assigns.target_node == {:remote, peer_a}
      assert failover(routed(other_key, :local), [peer_a]).assigns.target_node == :local
    end

    test "does not re-register the session on failover", %{key: key, peer_a: peer_a} do
      session = {"127.0.0.1", "failover-session-#{key}"}

      :ets.insert(
        :elixirgateway_sticky_sessions,
        {session, peer_a, System.system_time(:millisecond)}
      )

      mark_down(peer_a, key)

      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.put_req_header("x-session-id", "failover-session-#{key}")
        |> Plug.Conn.assign(:service_key, key)
        |> LoadDistributionRouter.call([])

      # Through call/2: pinned to a peer whose service is down, so it is served locally...
      assert conn.assigns.target_node == :local
      # ...but the session stays pinned, so traffic returns to the peer once it recovers
      assert [{^session, ^peer_a, _}] = :ets.lookup(:elixirgateway_sticky_sessions, session)
    end
  end
end
