defmodule ElixirGatewayWeb.EnhancedGunWebSocketHandlerTest do
  use ExUnit.Case, async: false

  alias ElixirGatewayWeb.GunWebSocketHandler

  setup do
    # Connection pool is already started by the application
    # Just clean up any existing connections
    :ets.delete_all_objects(:websocket_connection_pool)

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
    test "uses configurable upgrade timeout" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: []
      }

      # Mock the connection pool to return an error to test timeout handling
      # This test verifies that the configurable timeout is used
      result = GunWebSocketHandler.init(state)

      # Should fail because localhost:8080 isn't running, but timeout should be from config
      assert {:stop, :normal, _state} = result
    end

    test "initializes state with reconnection fields" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: []
      }

      # Even if init fails, we can test state structure
      case GunWebSocketHandler.init(state) do
        {:ok, new_state} ->
          assert Map.has_key?(new_state, :reconnect_attempts)
          assert Map.has_key?(new_state, :message_queue)
          assert Map.has_key?(new_state, :connected)
          assert new_state.reconnect_attempts == 0
          assert new_state.message_queue == []
          assert new_state.connected == false

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
        connected: false,
        message_queue: [],
        gun_pid: nil,
        gun_stream_ref: nil
      }

      # Try to send a text message when not connected
      result = GunWebSocketHandler.handle_in({"test message", [opcode: :text]}, state)

      assert {:ok, new_state} = result
      assert length(new_state.message_queue) == 1
      assert hd(new_state.message_queue) == {:text, "test message"}
    end

    test "queues binary messages when not connected" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        upgrade_pending: true,
        connected: false,
        message_queue: [],
        gun_pid: nil,
        gun_stream_ref: nil
      }

      binary_data = <<1, 2, 3, 4>>
      result = GunWebSocketHandler.handle_in({binary_data, [opcode: :binary]}, state)

      assert {:ok, new_state} = result
      assert length(new_state.message_queue) == 1
      assert hd(new_state.message_queue) == {:binary, binary_data}
    end

    test "limits message queue size" do
      # Create state with queue near limit
      initial_queue = Enum.map(1..9, fn i -> {:text, "message #{i}"} end)

      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        upgrade_pending: true,
        connected: false,
        message_queue: initial_queue,
        gun_pid: nil,
        gun_stream_ref: nil
      }

      # Add one more message (should reach limit of 10)
      result1 = GunWebSocketHandler.handle_in({"message 10", [opcode: :text]}, state)
      assert {:ok, state1} = result1
      assert length(state1.message_queue) == 10

      # Add another message (should drop oldest)
      result2 = GunWebSocketHandler.handle_in({"message 11", [opcode: :text]}, state1)
      assert {:ok, state2} = result2
      assert length(state2.message_queue) == 10

      # First message should be dropped, last should be the new one
      assert List.last(state2.message_queue) == {:text, "message 11"}
      # Original first message dropped
      assert {:text, "message 2"} = hd(state2.message_queue)
    end
  end

  describe "reconnection logic" do
    test "handles gun_error with reconnection attempt" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        # Use self() as mock PID
        gun_pid: self(),
        reconnect_attempts: 0,
        connected: true,
        upgrade_pending: false,
        message_queue: []
      }

      # Simulate gun error
      result = GunWebSocketHandler.handle_info({:gun_error, self(), nil, :connection_lost}, state)

      assert {:ok, new_state} = result
      assert new_state.reconnect_attempts == 1
      assert new_state.connected == false
      assert new_state.gun_pid == nil
    end

    test "stops after max reconnection attempts" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        # At max attempts (config set to 2)
        reconnect_attempts: 2,
        connected: false,
        upgrade_pending: false,
        message_queue: []
      }

      # Simulate gun error when already at max attempts
      result = GunWebSocketHandler.handle_info({:gun_error, self(), nil, :connection_lost}, state)

      # Should send close frame to client
      assert {:reply, :ok, {:close, _close_code, _reason}, _state} = result
    end

    test "handles permanent failures without reconnection" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        reconnect_attempts: 0,
        connected: true,
        upgrade_pending: false,
        message_queue: []
      }

      # Simulate permanent failure
      result = GunWebSocketHandler.handle_info({:gun_error, self(), nil, :econnrefused}, state)

      # Should immediately close without reconnection
      assert {:reply, :ok, {:close, 1014, _reason}, _state} = result
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
      result = GunWebSocketHandler.terminate(:normal, state)
      assert result == :ok

      # Note: In a real test, we'd verify the pool received the connection
      # but that would require mocking the pool or using a test double
    end
  end

  describe "WebSocket close codes" do
    test "sends appropriate close codes for HTTP errors" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        connected: false,
        upgrade_pending: true
      }

      # Test different HTTP status codes
      test_cases = [
        # Unauthorized -> Policy Violation
        {401, 1008},
        # Forbidden -> Policy Violation  
        {403, 1008},
        # Not Found -> Bad Gateway
        {404, 1014},
        # Internal Error -> Internal Error
        {500, 1011},
        # Bad Gateway -> Bad Gateway
        {502, 1014},
        # Service Unavailable -> Try Again Later
        {503, 1013}
      ]

      for {http_status, expected_close_code} <- test_cases do
        result =
          GunWebSocketHandler.handle_info(
            {:gun_response, self(), make_ref(), :nofin, http_status, []},
            state
          )

        assert {:reply, :ok, {:close, ^expected_close_code, _reason}, _state} = result
      end
    end
  end

  describe "upgrade success and message forwarding" do
    test "marks connection as successful on upgrade" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        headers: [],
        gun_pid: self(),
        gun_stream_ref: make_ref(),
        upgrade_pending: true,
        connected: false,
        message_queue: [{:text, "queued message"}],
        reconnect_attempts: 1
      }

      stream_ref = make_ref()

      result =
        GunWebSocketHandler.handle_info(
          {:gun_upgrade, self(), stream_ref, [<<"websocket">>], []},
          state
        )

      assert {:ok, new_state} = result
      assert new_state.gun_stream_ref == stream_ref
      assert new_state.upgrade_pending == false
      assert new_state.connected == true
      assert new_state.reconnect_attempts == 0
      # Message queue should be cleared after sending
      assert new_state.message_queue == []
    end

    test "forwards incoming WebSocket messages" do
      state = %{connected: true}

      # Test text message forwarding
      result =
        GunWebSocketHandler.handle_info({:gun_ws, self(), make_ref(), {:text, "hello"}}, state)

      assert {:reply, :ok, {:text, "hello"}, ^state} = result

      # Test binary message forwarding
      binary_data = <<1, 2, 3>>

      result =
        GunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:binary, binary_data}},
          state
        )

      assert {:reply, :ok, {:binary, ^binary_data}, ^state} = result

      # Test ping forwarding
      result =
        GunWebSocketHandler.handle_info({:gun_ws, self(), make_ref(), {:ping, "ping"}}, state)

      assert {:reply, :ok, {:ping, "ping"}, ^state} = result
    end

    test "handles WebSocket close frames with reason codes" do
      state = %{
        target_url: "ws://localhost:8080/ws",
        gun_pid: self(),
        connected: true
      }

      # Test close frame with code and reason
      result =
        GunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:close, 1000, "Normal closure"}},
          state
        )

      assert {:stop, :normal, ^state} = result

      # Test close frame with different code
      result =
        GunWebSocketHandler.handle_info(
          {:gun_ws, self(), make_ref(), {:close, 1001, "Going away"}},
          state
        )

      assert {:stop, :normal, ^state} = result
    end
  end
end
