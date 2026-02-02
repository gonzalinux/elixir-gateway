defmodule ElixirGatewayWeb.Integration.LoadDistributionTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias ElixirGateway.Cluster.{LoadDistributor, ConnectionRegistry}
  alias ElixirGatewayWeb.Plugs.{LoadDistributionRouter, RequestForwarder}

  @moduledoc """
  Integration tests for load distribution across the full request pipeline.

  NOTE: Full multi-node cluster tests require a more complex setup with actual
  distributed Erlang nodes. These tests focus on single-node behavior and the
  integration of components.

  For true multi-node testing, consider using:
  - `mix test.cluster` with peer nodes
  - Docker Compose with multiple gateway instances
  - Manual testing as described in the plan
  """

  setup do
    # Save original config
    original_config = Application.get_env(:elixirgateway, :cluster)

    # Set up test configuration
    test_config = [
      enabled: true,
      secret: "test-secret",
      node_name: "test-node",
      peers: [],
      load_distribution: [
        enabled: true,
        primary_weight: 70,
        secondary_weights: %{
          # These nodes don't exist, but we can test the logic
          :"gateway-cloud1@test" => 30,
          :"gateway-cloud2@test" => 15
        },
        min_requests_threshold: 20,
        window_seconds: 60
      ]
    ]

    Application.put_env(:elixirgateway, :cluster, test_config)

    # Start required processes
    {:ok, _registry} = start_supervised(ConnectionRegistry)
    {:ok, _distributor} = start_supervised(LoadDistributor)

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end
    end)

    :ok
  end

  describe "full request pipeline with load distribution" do
    test "routes requests consistently for same session" do
      # Create 10 requests with the same session ID
      session_id = "consistent-session-#{:rand.uniform(1000)}"

      results =
        for i <- 1..10 do
          conn =
            conn(:get, "/test/path")
            |> Map.put(:remote_ip, {127, 0, 0, 1})
            |> Plug.Conn.fetch_cookies()
            |> put_req_header("x-session-id", session_id)

          conn = LoadDistributionRouter.call(conn, [])
          {i, conn.assigns[:target_node]}
        end

      # All requests should route to the same target
      targets = Enum.map(results, fn {_i, target} -> target end)
      unique_targets = Enum.uniq(targets)

      assert length(unique_targets) == 1,
             "Expected all requests with same session to route to same target, got: #{inspect(unique_targets)}"
    end

    test "different sessions can route to different targets" do
      # Create requests with different session IDs
      results =
        for i <- 1..5 do
          conn =
            conn(:get, "/test")
            |> Map.put(:remote_ip, {127, 0, 0, i})
            |> Plug.Conn.fetch_cookies()
            |> put_req_header("x-session-id", "session-#{i}")

          conn = LoadDistributionRouter.call(conn, [])
          conn.assigns[:target_node]
        end

      # All should be :local since we don't have actual secondary nodes
      assert Enum.all?(results, fn target -> target == :local end)
    end

    test "traffic below threshold stays local" do
      # Record only 10 requests (below 20 threshold)
      for _ <- 1..10 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # New sessions should go local
      for i <- 1..5 do
        conn =
          conn(:get, "/test")
          |> Map.put(:remote_ip, {127, 0, 1, i})
          |> Plug.Conn.fetch_cookies()
          |> put_req_header("x-session-id", "below-threshold-#{i}")

        conn = LoadDistributionRouter.call(conn, [])
        assert conn.assigns[:target_node] == :local
      end
    end

    test "traffic above threshold uses weighted distribution" do
      # Record 30 requests (above 20 threshold)
      for _ <- 1..30 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # Verify we're above threshold
      refute LoadDistributor.below_traffic_threshold?()

      # New sessions should use weighted selection
      # Since we only have primary node active, all should still be :local
      for i <- 1..5 do
        conn =
          conn(:get, "/test")
          |> Map.put(:remote_ip, {127, 0, 2, i})
          |> Plug.Conn.fetch_cookies()
          |> put_req_header("x-session-id", "above-threshold-#{i}")

        conn = LoadDistributionRouter.call(conn, [])
        assert conn.assigns[:target_node] == :local
      end
    end
  end

  describe "session affinity preservation" do
    test "maintains affinity across multiple requests" do
      session_id = "affinity-test-#{:rand.uniform(10000)}"
      ip = {127, 0, 3, 1}

      # First request
      conn1 =
        conn(:get, "/api/user")
        |> Map.put(:remote_ip, ip)
        |> Plug.Conn.fetch_cookies()
        |> put_req_header("x-session-id", session_id)

      conn1 = LoadDistributionRouter.call(conn1, [])
      first_target = conn1.assigns[:target_node]

      # Multiple subsequent requests
      for i <- 1..10 do
        conn =
          conn(:get, "/api/data/#{i}")
          |> Map.put(:remote_ip, ip)
          |> Plug.Conn.fetch_cookies()
          |> put_req_header("x-session-id", session_id)

        conn = LoadDistributionRouter.call(conn, [])

        assert conn.assigns[:target_node] == first_target,
               "Request #{i} routed to different target than first request"
      end
    end
  end

  describe "weight distribution calculations" do
    test "calculates correct total weight for active nodes" do
      # Only primary node is active (secondary nodes don't exist)
      total = LoadDistributor.get_total_active_weight()
      assert total == 70
    end

    test "active node weights only include connected nodes" do
      weights = LoadDistributor.get_active_node_weights()

      # Should only have primary node
      assert map_size(weights) == 1
      assert weights[node()] == 70

      # Secondary nodes should not be included (not connected)
      refute Map.has_key?(weights, :"gateway-cloud1@test")
      refute Map.has_key?(weights, :"gateway-cloud2@test")
    end
  end

  describe "request recording and threshold tracking" do
    test "tracks requests accurately over time" do
      # Start below threshold
      assert LoadDistributor.below_traffic_threshold?()

      # Record requests to exceed threshold
      for _ <- 1..25 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # Should now be above threshold
      refute LoadDistributor.below_traffic_threshold?()
    end

    test "threshold detection affects routing decisions" do
      # Below threshold: should route to local
      below_threshold_conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 4, 1})
        |> Plug.Conn.fetch_cookies()
        |> put_req_header("x-session-id", "threshold-test-1")

      below_conn = LoadDistributionRouter.call(below_threshold_conn, [])
      assert below_conn.assigns[:target_node] == :local

      # Exceed threshold
      for _ <- 1..30 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # Above threshold: still routes to local (only node available)
      above_threshold_conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 4, 2})
        |> Plug.Conn.fetch_cookies()
        |> put_req_header("x-session-id", "threshold-test-2")

      above_conn = LoadDistributionRouter.call(above_threshold_conn, [])
      assert above_conn.assigns[:target_node] == :local
    end
  end

  describe "metrics integration" do
    test "load distributor provides metrics data" do
      # Test metrics functions don't crash
      assert is_boolean(LoadDistributor.enabled?())
      assert is_boolean(LoadDistributor.below_traffic_threshold?())
      assert is_integer(LoadDistributor.get_total_active_weight())
      assert is_list(LoadDistributor.get_node_weights_for_metrics())
    end

    test "metrics reflect current state" do
      # Should be enabled
      assert LoadDistributor.enabled?()

      # Total weight should be 70 (only primary active)
      assert LoadDistributor.get_total_active_weight() == 70

      # Should initially be below threshold
      assert LoadDistributor.below_traffic_threshold?()
    end
  end

  describe "failure handling" do
    test "handles missing target_url gracefully" do
      # Simulate a request that makes it through LoadDistributionRouter
      # but doesn't have a target_url (shouldn't happen in practice)
      conn =
        conn(:get, "/test")
        |> Map.put(:remote_ip, {127, 0, 5, 1})
        |> Plug.Conn.fetch_cookies()
        |> LoadDistributionRouter.call([])

      # RequestForwarder should handle this gracefully
      # (it returns conn unchanged if no target_url)
      result = RequestForwarder.call(conn, [])
      refute result.halted
    end
  end
end
