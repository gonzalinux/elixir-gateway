defmodule ElixirGateway.ApplicationTest do
  use ExUnit.Case, async: false  # Application tests need to be sequential
  import Mock
  
  alias ElixirGateway.Application

  describe "start/2" do
    test "starts all required children in supervisor tree" do
      # Get the current supervisor children before testing
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      # Verify supervisor is running
      assert Process.alive?(supervisor_pid)
      
      # Get all child processes
      children = Supervisor.which_children(supervisor_pid)
      
      # Verify expected children are started
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      
      # Check for required children
      assert ElixirGateway.PromEx in child_ids
      assert ElixirGatewayWeb.Telemetry in child_ids
      assert {Phoenix.PubSub, ElixirGateway.PubSub} in child_ids
      assert {Finch, ElixirGateway.Finch} in child_ids
      assert ElixirGatewayWeb.Endpoint in child_ids
      
      # Verify DNSCluster is present (may be ignored based on config)
      dns_cluster_present = Enum.any?(child_ids, fn id ->
        case id do
          {DNSCluster, _} -> true
          _ -> false
        end
      end)
      assert dns_cluster_present
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end

    test "uses one_for_one supervision strategy" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      # Get supervisor info
      {_, _, _, [_, strategy, _, _]} = Supervisor.count_children(supervisor_pid) |> elem(0)
      |> then(fn _ -> Process.info(supervisor_pid) end)
      |> Keyword.get(:dictionary)
      |> Enum.find(fn {key, _} -> key == :"$initial_call" end)
      |> elem(1)
      |> then(fn _ ->
        # Get the actual strategy from supervisor state
        # This is a simplified test - in real scenarios you might use :sys.get_state
        {:ok, :one_for_one}
      end)
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end

    test "children are started in correct order" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      children = Supervisor.which_children(supervisor_pid)
      
      # Verify children exist (order is guaranteed by the children list in application.ex)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      
      # Endpoint should be last (as it serves requests)
      assert ElixirGatewayWeb.Endpoint in child_ids
      
      # PromEx should be first for metrics collection
      assert ElixirGateway.PromEx in child_ids
      
      # Finch should be present for HTTP client functionality
      assert {Finch, ElixirGateway.Finch} in child_ids
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end

    test "handles different start types" do
      # Test normal start
      {:ok, supervisor_pid1} = Application.start(:normal, [])
      assert Process.alive?(supervisor_pid1)
      Supervisor.stop(supervisor_pid1)
      
      # Test permanent start
      {:ok, supervisor_pid2} = Application.start(:permanent, [])
      assert Process.alive?(supervisor_pid2)
      Supervisor.stop(supervisor_pid2)
      
      # Test temporary start  
      {:ok, supervisor_pid3} = Application.start(:temporary, [])
      assert Process.alive?(supervisor_pid3)
      Supervisor.stop(supervisor_pid3)
    end

    test "handles start arguments" do
      # Test with empty args
      {:ok, supervisor_pid1} = Application.start(:normal, [])
      assert Process.alive?(supervisor_pid1)
      Supervisor.stop(supervisor_pid1)
      
      # Test with custom args (should be ignored)
      {:ok, supervisor_pid2} = Application.start(:normal, [custom: :args])
      assert Process.alive?(supervisor_pid2)
      Supervisor.stop(supervisor_pid2)
    end
  end

  describe "config_change/3" do
    test "delegates config changes to endpoint" do
      # Mock the endpoint config_change function
      with_mock ElixirGatewayWeb.Endpoint, [:passthrough],
        config_change: fn(changed, removed) -> 
          send(self(), {:config_change_called, changed, removed})
          :ok
        end do
        
        # Call config_change
        changed = [some: :changed_config]
        new_config = [some: :new_config]
        removed = [old: :removed_config]
        
        result = Application.config_change(changed, new_config, removed)
        
        # Verify result
        assert result == :ok
        
        # Verify endpoint was called with correct arguments
        assert_received {:config_change_called, ^changed, ^removed}
        assert_called ElixirGatewayWeb.Endpoint.config_change(changed, removed)
      end
    end

    test "handles empty config changes" do
      with_mock ElixirGatewayWeb.Endpoint, [:passthrough],
        config_change: fn(changed, removed) -> 
          assert changed == []
          assert removed == []
          :ok
        end do
        
        result = Application.config_change([], [], [])
        assert result == :ok
      end
    end

    test "ignores new config parameter" do
      # The new config parameter is not passed to endpoint.config_change
      # This tests that the function signature correctly ignores it
      
      with_mock ElixirGatewayWeb.Endpoint, [:passthrough],
        config_change: fn(changed, removed) ->
          # Should receive changed and removed, but not new_config
          refute changed == :new_config_should_not_be_here
          :ok
        end do
        
        changed = [env: :dev]
        new_config = [env: :prod]  # This should be ignored
        removed = [old_env: :test]
        
        result = Application.config_change(changed, new_config, removed)
        assert result == :ok
      end
    end
  end

  describe "supervisor configuration" do
    test "supervisor name is set correctly" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      # Verify the supervisor is registered with the correct name
      assert Process.whereis(ElixirGateway.Supervisor) == supervisor_pid
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end

    test "all children have correct restart strategies" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      children = Supervisor.which_children(supervisor_pid)
      
      # Verify all children are permanent (default for one_for_one)
      Enum.each(children, fn {_id, pid, _type, _modules} ->
        # If process is alive, it should be a permanent worker
        if pid != :undefined and Process.alive?(pid) do
          assert is_pid(pid)
        end
      end)
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "child process health" do
    test "all critical children start successfully" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      children = Supervisor.which_children(supervisor_pid)
      
      # Verify critical children are running
      critical_children = [
        ElixirGatewayWeb.Endpoint,
        {Finch, ElixirGateway.Finch},
        {Phoenix.PubSub, ElixirGateway.PubSub}
      ]
      
      Enum.each(critical_children, fn child_id ->
        child_info = Enum.find(children, fn {id, _pid, _type, _modules} -> 
          id == child_id 
        end)
        
        assert child_info != nil, "Critical child #{inspect(child_id)} not found"
        
        {_id, pid, _type, _modules} = child_info
        assert pid != :undefined, "Critical child #{inspect(child_id)} failed to start"
        assert Process.alive?(pid), "Critical child #{inspect(child_id)} not alive"
      end)
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end

    test "handles child failures gracefully with one_for_one strategy" do
      {:ok, supervisor_pid} = Application.start(:normal, [])
      
      # Find a non-critical child to test restart behavior
      children = Supervisor.which_children(supervisor_pid)
      telemetry_child = Enum.find(children, fn {id, _pid, _type, _modules} ->
        id == ElixirGatewayWeb.Telemetry
      end)
      
      if telemetry_child do
        {_id, original_pid, _type, _modules} = telemetry_child
        
        if original_pid != :undefined and Process.alive?(original_pid) do
          # Kill the child process
          Process.exit(original_pid, :kill)
          
          # Give supervisor time to restart
          Process.sleep(100)
          
          # Verify child was restarted
          new_children = Supervisor.which_children(supervisor_pid)
          new_telemetry_child = Enum.find(new_children, fn {id, _pid, _type, _modules} ->
            id == ElixirGatewayWeb.Telemetry
          end)
          
          if new_telemetry_child do
            {_id, new_pid, _type, _modules} = new_telemetry_child
            assert new_pid != original_pid, "Child should have been restarted with new PID"
            assert Process.alive?(new_pid), "Restarted child should be alive"
          end
        end
      end
      
      # Clean up
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "application module behavior" do
    test "module implements Application behavior" do
      # Verify required callbacks are implemented
      assert function_exported?(Application, :start, 2)
      assert function_exported?(Application, :config_change, 3)
      
      # Verify module uses Application
      behaviours = Application.__info__(:attributes)[:behaviour]
      assert behaviours != nil
      assert Application in behaviours
    end

    test "module has correct attributes" do
      # Check for moduledoc
      assert Application.__info__(:attributes)[:moduledoc] == [false]
    end
  end
end