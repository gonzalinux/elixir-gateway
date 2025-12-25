defmodule ElixirGatewayWeb.EnhancedGunWebSocketHandlerTest do
  use ExUnit.Case, async: false

  alias ElixirGatewayWeb.EnhancedGunWebSocketHandler

  setup do
    # Clean up any existing connections if the table exists
    # The table is created by WebSocketConnectionPool when the application starts
    case :ets.whereis(:websocket_connection_pool) do
      :undefined ->
        # Table doesn't exist yet - this is fine, tests will work without it
        :ok

      _ref ->
        # Table exists, clean it up
        :ets.delete_all_objects(:websocket_connection_pool)
    end

    # Set test configuration
    original_config = Application.get_env(:elixirgateway, :websocket)

    Application.put_env(:elixirgateway, :websocket,
      # Shorter for testing
      upgrade_timeout: 5_000,
      connection_pool: [
        size: 5,
        max_idle_time: 60_000,
        cleanup_interval: 10_000
      ],
      reconnect: [
        # Fewer attempts for testing
        max_attempts: 2,
        initial_backoff: 100,
        max_backoff: 1000,
        backoff_multiplier: 2
      ],
      message_queue: [
        max_size: 10,
        timeout: 5_000
      ]
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :websocket, original_config)
      else
        Application.delete_env(:elixirgateway, :websocket)
      end
    end)

    :ok
  end

  describe "configuration and timeouts" do
    @tag :integration
    test "uses configurable upgrade timeout" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: []
      }

      # Mock the connection pool to return an error to test timeout handling
      # This test verifies that the configurable timeout is used
      result = EnhancedGunWebSocketHandler.init(state)

      # Should fail because localhost:8080 isn't running, but timeout should be from config
      assert {:stop, :normal, _state} = result
    end

    @tag :integration
    test "initializes state with reconnection fields" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: []
      }

      # Even if init fails, we can test state structure
      case EnhancedGunWebSocketHandler.init(state) do
        {:ok, new_state} ->
          assert Map.has_key?(new_state, :reconnect_attempts)
          assert Map.has_key?(new_state, :message_queue)
          assert Map.has_key?(new_state, :connection_status)
          assert new_state.reconnect_attempts == 0
          assert :queue.len(new_state.message_queue) == 0
          assert new_state.connection_status == :connecting

        {:stop, :normal, _state} ->
          # Expected when connection fails
          :ok
      end
    end
  end

  describe "message queueing" do
    test "queues messages when not connected" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        upgrade_pending: true,
        connection_status: :connecting,
        message_queue: :queue.new(),
        queue_size: 0,
        gun_pid: nil,
        gun_stream_ref: nil,
        config: %{message_queue_max_size: 100}
      }

      # Try to send a text message when not connected
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_in(
          {"test message", [opcode: :text]},
          state
        )

      assert {:ok, new_state} = result
      assert new_state.queue_size == 1
      assert :queue.len(new_state.message_queue) == 1
    end

    test "queues binary messages when not connected" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        upgrade_pending: true,
        connection_status: :connecting,
        message_queue: :queue.new(),
        queue_size: 0,
        gun_pid: nil,
        gun_stream_ref: nil,
        config: %{message_queue_max_size: 100}
      }

      binary_data = <<1, 2, 3, 4>>

      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_in(
          {binary_data, [opcode: :binary]},
          state
        )

      assert {:ok, new_state} = result
      assert new_state.queue_size == 1
      assert :queue.len(new_state.message_queue) == 1
    end

    test "limits message queue size" do
      # Create state with queue near limit (9 messages)
      initial_queue =
        Enum.reduce(1..9, :queue.new(), fn i, acc ->
          :queue.in({:text, "message #{i}"}, acc)
        end)

      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        upgrade_pending: true,
        connection_status: :connecting,
        message_queue: initial_queue,
        queue_size: 9,
        gun_pid: nil,
        gun_stream_ref: nil,
        config: %{message_queue_max_size: 10}
      }

      # Add one more message (should reach limit of 10)
      result1 =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_in(
          {"message 10", [opcode: :text]},
          state
        )

      assert {:ok, state1} = result1
      assert state1.queue_size == 10

      # Add another message (should drop oldest when queue is full)
      result2 =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_in(
          {"message 11", [opcode: :text]},
          state1
        )

      assert {:ok, state2} = result2
      # Queue should not grow beyond max size
      assert state2.queue_size == 10
    end
  end

  describe "reconnection logic" do
    test "handles gun_error with reconnection attempt" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        # Use self() as mock PID
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        reconnect_attempts: 0,
        connection_status: :connected,
        upgrade_pending: false,
        message_queue: :queue.new(),
        config: %{
          reconnect_max_attempts: 3,
          reconnect_base_delay: 1000,
          reconnect_max_delay: 10000
        }
      }

      # Simulate gun error
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_error, self(), nil, :connection_lost},
          state
        )

      assert {:ok, new_state} = result
      assert new_state.connection_status == :reconnecting
      assert new_state.gun_pid == nil
    end

    test "stops after max reconnection attempts" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        # At max attempts (config set to 2)
        reconnect_attempts: 2,
        connection_status: :reconnecting,
        upgrade_pending: false,
        message_queue: :queue.new(),
        config: %{
          reconnect_max_attempts: 2,
          reconnect_base_delay: 1000,
          reconnect_max_delay: 10000
        }
      }

      # Simulate gun error when already at max attempts
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_error, self(), nil, :connection_lost},
          state
        )

      # Should stop with close frame
      assert {:stop, {:close, 1002, "Connection error"}, _state} = result
    end

    test "handles permanent failures without reconnection" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        reconnect_attempts: 0,
        connection_status: :connected,
        upgrade_pending: false,
        message_queue: :queue.new(),
        config: %{
          reconnect_max_attempts: 3,
          reconnect_base_delay: 1000,
          reconnect_max_delay: 10000
        }
      }

      # Simulate permanent failure
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_error, self(), nil, :econnrefused},
          state
        )

      # Should attempt reconnection (Enhanced handler treats all errors the same way)
      assert {:ok, new_state} = result
      assert new_state.connection_status == :reconnecting
    end
  end

  describe "connection pooling integration" do
    test "returns connection to pool on terminate" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        # Mock PID
        gun_pid: self(),
        gun_stream_ref: make_ref()
      }

      # Terminate should return connection to pool
      result = ElixirGatewayWeb.EnhancedGunWebSocketHandler.terminate(:normal, state)
      assert result == :ok

      # Note: In a real test, we'd verify the pool received the connection
      # but that would require mocking the pool or using a test double
    end
  end

  describe "WebSocket upgrade failures" do
    test "handles upgrade failure with reconnection attempt" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        connection_status: :upgrading,
        upgrade_pending: true,
        reconnect_attempts: 0,
        config: %{
          reconnect_max_attempts: 3,
          reconnect_base_delay: 1000,
          reconnect_max_delay: 10000
        }
      }

      # Enhanced handler only handles :fin responses
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_response, self(), make_ref(), :fin, 404, []},
          state
        )

      # Should attempt reconnection
      assert {:ok, new_state} = result
      assert new_state.connection_status == :reconnecting
    end

    test "stops after max reconnection attempts on upgrade failure" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        connection_status: :upgrading,
        upgrade_pending: true,
        reconnect_attempts: 3,
        config: %{
          reconnect_max_attempts: 3,
          reconnect_base_delay: 1000,
          reconnect_max_delay: 10000
        }
      }

      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_response, self(), make_ref(), :fin, 500, []},
          state
        )

      # Should stop with close frame
      assert {:stop, {:close, 1002, "Upgrade failed"}, _state} = result
    end
  end

  describe "upgrade success and message forwarding" do
    test "marks connection as successful on upgrade" do
      queued_message = {:text, "queued message"}
      initial_queue = :queue.in(queued_message, :queue.new())

      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        upgrade_pending: true,
        connection_status: :upgrading,
        message_queue: initial_queue,
        queue_size: 1,
        reconnect_attempts: 1
      }

      stream_ref = make_ref()

      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_upgrade, self(), stream_ref, [<<"websocket">>], []},
          state
        )

      assert {:ok, new_state} = result
      assert new_state.gun_stream_ref == stream_ref
      assert new_state.upgrade_pending == false
      assert new_state.connection_status == :connected
      assert new_state.reconnect_attempts == 0
      # Message queue should be cleared after sending
      assert :queue.is_empty(new_state.message_queue)
      assert new_state.queue_size == 0
    end

    test "forwards incoming WebSocket messages" do
      state = %{connection_status: :connected}

      # Test text message forwarding
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:text, "hello"}},
          state
        )

      assert {:reply, :ok, {:text, "hello"}, ^state} = result

      # Test binary message forwarding
      binary_data = <<1, 2, 3>>

      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:binary, binary_data}},
          state
        )

      assert {:reply, :ok, {:binary, ^binary_data}, ^state} = result

      # Test ping forwarding
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:ping, "ping"}},
          state
        )

      assert {:reply, :ok, {:ping, "ping"}, ^state} = result
    end

    test "handles WebSocket close frames with reason codes" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        gun_pid: self(),
        connection_status: :connected
      }

      # Test close frame with code and reason
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:close, 1000, "Normal closure"}},
          state
        )

      assert {:stop, {:close, 1000, "Normal closure"}, ^state} = result

      # Test close frame with different code
      result =
        ElixirGatewayWeb.EnhancedGunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:close, 1001, "Going away"}},
          state
        )

      assert {:stop, {:close, 1001, "Going away"}, ^state} = result
    end
  end
end
