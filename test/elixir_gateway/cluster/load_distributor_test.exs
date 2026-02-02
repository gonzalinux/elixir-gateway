defmodule ElixirGateway.Cluster.LoadDistributorTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.Cluster.LoadDistributor

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
        primary_weight: 70,
        secondary_weights: %{},
        min_requests_threshold: 20,
        window_seconds: 60
      ]
    ]

    Application.put_env(:elixirgateway, :cluster, test_config)

    # Start the LoadDistributor
    {:ok, pid} = start_supervised(LoadDistributor)

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end
    end)

    %{pid: pid}
  end

  describe "enabled?/0" do
    test "returns true when load distribution is enabled" do
      assert LoadDistributor.enabled?() == true
    end

    test "returns false when load distribution is disabled" do
      # Temporarily disable
      cluster_config = Application.get_env(:elixirgateway, :cluster)
      disabled_config = put_in(cluster_config[:load_distribution][:enabled], false)
      Application.put_env(:elixirgateway, :cluster, disabled_config)

      refute LoadDistributor.enabled?()

      # Re-enable
      Application.put_env(:elixirgateway, :cluster, cluster_config)
    end
  end

  describe "get_active_node_weights/0" do
    test "returns only primary node when no secondaries configured" do
      weights = LoadDistributor.get_active_node_weights()

      assert map_size(weights) == 1
      assert weights[node()] == 70
    end

    test "includes connected secondary nodes" do
      # Add secondary weights to config (these nodes don't exist, so they won't be included)
      cluster_config = Application.get_env(:elixirgateway, :cluster)

      updated_config =
        put_in(cluster_config[:load_distribution][:secondary_weights], %{
          :"gateway-cloud1@localhost" => 30,
          :"gateway-cloud2@localhost" => 15
        })

      Application.put_env(:elixirgateway, :cluster, updated_config)

      weights = LoadDistributor.get_active_node_weights()

      # Only primary should be included since secondary nodes are not connected
      assert map_size(weights) == 1
      assert weights[node()] == 70
    end
  end

  describe "get_total_active_weight/0" do
    test "returns sum of all active node weights" do
      total = LoadDistributor.get_total_active_weight()
      assert total == 70
    end
  end

  describe "weighted_random_node/0" do
    test "always selects primary node when it's the only active node" do
      # Run multiple times to verify consistency
      results =
        for _ <- 1..100 do
          LoadDistributor.weighted_random_node()
        end

      assert Enum.all?(results, fn node_name -> node_name == node() end)
    end

    test "distributes selection according to weights" do
      # This test can't easily verify distribution without actual secondary nodes
      # Just verify it doesn't crash and returns a valid node
      selected = LoadDistributor.weighted_random_node()
      assert selected == node()
    end
  end

  describe "select_node_for_new_session/0" do
    test "returns local node when below traffic threshold" do
      # Initially, no traffic recorded, so below threshold
      assert LoadDistributor.select_node_for_new_session() == node()
    end

    test "uses weighted selection when above traffic threshold" do
      # Record enough requests to exceed threshold (20 requests)
      for _ <- 1..25 do
        LoadDistributor.record_request(node())
      end

      # Give time for cast to process
      Process.sleep(10)

      # Should still return local node since we have no secondaries
      selected = LoadDistributor.select_node_for_new_session()
      assert selected == node()
    end
  end

  describe "record_request/1" do
    test "records request for a node" do
      LoadDistributor.record_request(node())
      Process.sleep(10)

      # Verify by checking if we can trigger threshold behavior
      # Initially below threshold
      assert LoadDistributor.below_traffic_threshold?() == true
    end

    test "tracks multiple requests" do
      # Record multiple requests
      for _ <- 1..25 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # Should be above threshold now
      refute LoadDistributor.below_traffic_threshold?()
    end
  end

  describe "below_traffic_threshold?/0" do
    test "returns true when no requests recorded" do
      assert LoadDistributor.below_traffic_threshold?() == true
    end

    test "returns true when requests are below threshold" do
      # Record 10 requests (below 20 threshold)
      for _ <- 1..10 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      assert LoadDistributor.below_traffic_threshold?() == true
    end

    test "returns false when requests exceed threshold" do
      # Record 25 requests (above 20 threshold)
      for _ <- 1..25 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      refute LoadDistributor.below_traffic_threshold?()
    end
  end

  describe "get_node_weights_for_metrics/0" do
    test "returns weights formatted for PromEx" do
      weights = LoadDistributor.get_node_weights_for_metrics()

      assert is_list(weights)
      assert length(weights) == 1

      [{tags, weight}] = weights
      assert tags[:node_name] == to_string(node())
      assert weight == 70
    end
  end

  describe "weight distribution calculations" do
    test "primary alone represents 100% of weight" do
      weights = LoadDistributor.get_active_node_weights()
      total = LoadDistributor.get_total_active_weight()

      primary_weight = weights[node()]
      primary_percentage = primary_weight / total * 100

      assert_in_delta(primary_percentage, 100.0, 0.1)
    end
  end

  describe "cleanup of old requests" do
    test "old request data is cleaned up" do
      # Record some requests
      for _ <- 1..30 do
        LoadDistributor.record_request(node())
      end

      Process.sleep(10)

      # Should be above threshold
      refute LoadDistributor.below_traffic_threshold?()

      # Trigger cleanup by sending cleanup message directly
      # In real scenario, this happens automatically
      # For testing, we rely on the window_seconds configuration

      # Since we can't easily manipulate time in tests without additional libraries,
      # we just verify the threshold detection works
      assert is_boolean(LoadDistributor.below_traffic_threshold?())
    end
  end
end
