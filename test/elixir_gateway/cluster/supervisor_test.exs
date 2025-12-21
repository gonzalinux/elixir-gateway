defmodule ElixirGateway.Cluster.SupervisorTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.Cluster.Supervisor, as: ClusterSupervisor

  setup do
    # Save original config
    original_config = Application.get_env(:elixirgateway, :cluster)

    on_exit(fn ->
      # Restore original config or delete if it didn't exist
      if original_config do
        Application.put_env(:elixirgateway, :cluster, original_config)
      else
        Application.delete_env(:elixirgateway, :cluster)
      end

      # Stop supervisor if it's running
      case Process.whereis(ClusterSupervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid, :normal)
      end
    end)

    :ok
  end

  describe "when clustering is disabled (default)" do
    test "starts successfully with no children" do
      # Set disabled config
      Application.put_env(:elixirgateway, :cluster, enabled: false)

      assert {:ok, pid} = ClusterSupervisor.start_link([])
      assert Process.alive?(pid)

      # Verify no children are running
      children = Supervisor.which_children(pid)
      assert children == []

      Supervisor.stop(pid, :normal)
    end

    test "starts successfully with nil config" do
      # Delete config entirely
      Application.delete_env(:elixirgateway, :cluster)

      assert {:ok, pid} = ClusterSupervisor.start_link([])
      assert Process.alive?(pid)

      children = Supervisor.which_children(pid)
      assert children == []

      Supervisor.stop(pid, :normal)
    end
  end

  describe "when clustering is enabled" do
    test "raises error if secret is missing" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        node_name: "test-node",
        peers: ["peer1:9100"]
        # secret is missing
      )

      assert_raise ArgumentError, ~r/required field :secret/, fn ->
        ClusterSupervisor.start_link([])
      end
    end

    test "raises error if node_name is missing" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        peers: ["peer1:9100"]
        # node_name is missing
      )

      assert_raise ArgumentError, ~r/required field :node_name/, fn ->
        ClusterSupervisor.start_link([])
      end
    end

    test "raises error if peers is missing" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-node"
        # peers is missing
      )

      assert_raise ArgumentError, ~r/required field :peers/, fn ->
        ClusterSupervisor.start_link([])
      end
    end

    test "raises error if peers is empty" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "test-node",
        peers: []
        # peers is empty
      )

      assert_raise ArgumentError, ~r/required field :peers/, fn ->
        ClusterSupervisor.start_link([])
      end
    end

    test "raises error if secret is empty string" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: "",
        node_name: "test-node",
        peers: ["peer1:9100"]
      )

      assert_raise ArgumentError, ~r/required field :secret/, fn ->
        ClusterSupervisor.start_link([])
      end
    end

    test "raises error if node_name is empty string" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        secret: String.duplicate("a", 64),
        node_name: "  ",
        peers: ["peer1:9100"]
      )

      assert_raise ArgumentError, ~r/required field :node_name/, fn ->
        ClusterSupervisor.start_link([])
      end
    end
  end

  describe "configuration validation message" do
    test "provides helpful error message with example config" do
      Application.put_env(:elixirgateway, :cluster,
        enabled: true,
        node_name: "test-node"
        # Missing secret and peers
      )

      assert_raise ArgumentError, fn ->
        ClusterSupervisor.start_link([])
      end
    rescue
      error in ArgumentError ->
        message = Exception.message(error)
        assert message =~ "config :elixirgateway, :cluster"
        assert message =~ "enabled: true"
        assert message =~ "CLUSTER_SECRET"
    end
  end
end
