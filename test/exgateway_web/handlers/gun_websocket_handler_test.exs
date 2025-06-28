defmodule ElixirGatewayWeb.GunWebSocketHandlerTest do
  use ExUnit.Case, async: false  # Gun processes need to be sequential
  import Mock
  
  alias ElixirGatewayWeb.GunWebSocketHandler

  setup do
    # Note: :gun.flush/0 is not available, using manual cleanup
    
    # Mock state for testing
    state = %{
      target_url: "ws://localhost:8080/socket",
      headers: [{"authorization", "Bearer test-token"}],
      host: "test.example.com"
    }
    
    {:ok, state: state}
  end

  describe "init/1" do
    test "initializes with successful Gun connection", %{state: state} do
      # Mock successful Gun connection
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      with_mock :gun, [:unstick],
        open: fn(_host, _port, _opts) -> {:ok, gun_pid} end,
        await_up: fn(_pid, _timeout) -> {:ok, :http} end,
        ws_upgrade: fn(_pid, _path, _headers) -> stream_ref end do
        
        result = GunWebSocketHandler.init(state)
        
        assert {:ok, new_state} = result
        assert new_state.gun_pid == gun_pid
        assert new_state.gun_stream_ref == stream_ref
        assert new_state.upgrade_pending == true
        
        # Verify Gun calls
        assert_called :gun.open(~c"localhost", 8080, :_)
        assert_called :gun.await_up(gun_pid, 10000)
        assert_called :gun.ws_upgrade(gun_pid, "/socket", :_)
      end
    end

    test "fails initialization when Gun connection fails", %{state: state} do
      with_mock :gun, [:unstick],
        open: fn(_host, _port, _opts) -> {:error, :timeout} end do
        
        result = GunWebSocketHandler.init(state)
        
        assert {:stop, :normal, ^state} = result
        assert_called :gun.open(~c"localhost", 8080, :_)
      end
    end

    test "fails initialization when Gun await_up fails", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      
      with_mock :gun, [:unstick],
        open: fn(_host, _port, _opts) -> {:ok, gun_pid} end,
        await_up: fn(_pid, _timeout) -> {:error, :timeout} end,
        close: fn(_pid) -> :ok end do
        
        result = GunWebSocketHandler.init(state)
        
        assert {:stop, :normal, ^state} = result
        assert_called :gun.close(gun_pid)
      end
    end

    test "handles WSS (secure) target URLs correctly", %{state: state} do
      wss_state = %{state | target_url: "wss://secure.example.com:9443/socket"}
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      with_mock :gun, [:unstick],
        open: fn(host, port, opts) ->
          assert host == ~c"secure.example.com"
          assert port == 443  # Should default to 443 for wss
          {:ok, gun_pid}
        end,
        await_up: fn(_pid, _timeout) -> {:ok, :http} end,
        ws_upgrade: fn(_pid, _path, _headers) -> stream_ref end do
        
        result = GunWebSocketHandler.init(wss_state)
        
        assert {:ok, _new_state} = result
      end
    end

    test "parses target URL with query parameters", %{state: state} do
      query_state = %{state | target_url: "ws://localhost:8080/socket?token=abc123&room=general"}
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      
      with_mock :gun, [:unstick],
        open: fn(_host, _port, _opts) -> {:ok, gun_pid} end,
        await_up: fn(_pid, _timeout) -> {:ok, :http} end,
        ws_upgrade: fn(_pid, path, _headers) ->
          assert path == "/socket?token=abc123&room=general"
          make_ref()
        end do
        
        GunWebSocketHandler.init(query_state)
        
        assert_called :gun.ws_upgrade(gun_pid, "/socket?token=abc123&room=general", :_)
      end
    end
  end

  describe "handle_in/2 - incoming WebSocket messages" do
    test "forwards text messages when upgrade is complete", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      complete_state = %{state | 
        gun_pid: gun_pid, 
        gun_stream_ref: stream_ref, 
        upgrade_pending: false
      }
      
      with_mock :gun, [:unstick],
        ws_send: fn(_pid, _stream_ref, _frame) -> :ok end do
        
        result = GunWebSocketHandler.handle_in({"Hello, World!", [opcode: :text]}, complete_state)
        
        assert {:ok, ^complete_state} = result
        assert_called :gun.ws_send(gun_pid, stream_ref, {:text, "Hello, World!"})
      end
    end

    test "forwards binary messages when upgrade is complete", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      complete_state = %{state | 
        gun_pid: gun_pid, 
        gun_stream_ref: stream_ref, 
        upgrade_pending: false
      }
      
      binary_data = <<1, 2, 3, 4>>
      
      with_mock :gun, [:unstick],
        ws_send: fn(_pid, _stream_ref, _frame) -> :ok end do
        
        result = GunWebSocketHandler.handle_in({binary_data, [opcode: :binary]}, complete_state)
        
        assert {:ok, ^complete_state} = result
        assert_called :gun.ws_send(gun_pid, stream_ref, {:binary, binary_data})
      end
    end

    test "forwards ping messages when upgrade is complete", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      complete_state = %{state | 
        gun_pid: gun_pid, 
        gun_stream_ref: stream_ref, 
        upgrade_pending: false
      }
      
      payload = "ping_payload"
      
      with_mock :gun, [:unstick],
        ws_send: fn(_pid, _stream_ref, _frame) -> :ok end do
        
        result = GunWebSocketHandler.handle_in({payload, [opcode: :ping]}, complete_state)
        
        assert {:ok, ^complete_state} = result
        assert_called :gun.ws_send(gun_pid, stream_ref, {:ping, payload})
      end
    end

    test "handles pong messages gracefully", %{state: state} do
      complete_state = %{state | upgrade_pending: false}
      
      result = GunWebSocketHandler.handle_in({"pong_payload", [opcode: :pong]}, complete_state)
      
      assert {:ok, ^complete_state} = result
    end

    test "queues messages when upgrade is pending", %{state: state} do
      pending_state = %{state | upgrade_pending: true}
      
      result = GunWebSocketHandler.handle_in({"test message", [opcode: :text]}, pending_state)
      
      assert {:ok, ^pending_state} = result
    end

    test "handles missing gun stream gracefully", %{state: state} do
      no_stream_state = %{state | gun_stream_ref: nil, upgrade_pending: false}
      
      result = GunWebSocketHandler.handle_in({"test", [opcode: :text]}, no_stream_state)
      
      assert {:ok, ^no_stream_state} = result
    end
  end

  describe "handle_info/2 - Gun events" do
    test "handles successful Gun WebSocket upgrade", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      initial_stream_ref = make_ref()
      upgrade_stream_ref = make_ref()
      
      pending_state = %{state | 
        gun_pid: gun_pid, 
        gun_stream_ref: initial_stream_ref,
        upgrade_pending: true
      }
      
      upgrade_msg = {:gun_upgrade, gun_pid, upgrade_stream_ref, [<<"websocket">>], []}
      result = GunWebSocketHandler.handle_info(upgrade_msg, pending_state)
      
      assert {:ok, new_state} = result
      assert new_state.gun_stream_ref == upgrade_stream_ref
      assert new_state.upgrade_pending == false
    end

    test "handles Gun WebSocket upgrade failure", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      pending_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      with_mock :gun, [:unstick],
        await_body: fn(_pid, _stream_ref, _timeout) -> {:ok, "Error details"} end do
        
        error_msg = {:gun_response, gun_pid, stream_ref, :nofin, 404, []}
        result = GunWebSocketHandler.handle_info(error_msg, pending_state)
        
        assert {:stop, :normal, ^pending_state} = result
      end
    end

    test "handles Gun errors", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      error_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      error_msg = {:gun_error, gun_pid, stream_ref, :timeout}
      result = GunWebSocketHandler.handle_info(error_msg, error_state)
      
      assert {:stop, :normal, ^error_state} = result
    end

    test "forwards text messages from Gun to client", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      connected_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      ws_msg = {:gun_ws, gun_pid, stream_ref, {:text, "Hello from server"}}
      result = GunWebSocketHandler.handle_info(ws_msg, connected_state)
      
      assert {:reply, :ok, {:text, "Hello from server"}, ^connected_state} = result
    end

    test "forwards binary messages from Gun to client", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      connected_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      binary_data = <<5, 6, 7, 8>>
      ws_msg = {:gun_ws, gun_pid, stream_ref, {:binary, binary_data}}
      result = GunWebSocketHandler.handle_info(ws_msg, connected_state)
      
      assert {:reply, :ok, {:binary, binary_data}, ^connected_state} = result
    end

    test "forwards ping messages from Gun to client", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      connected_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      ping_msg = {:gun_ws, gun_pid, stream_ref, {:ping, "server_ping"}}
      result = GunWebSocketHandler.handle_info(ping_msg, connected_state)
      
      assert {:reply, :ok, {:ping, "server_ping"}, ^connected_state} = result
    end

    test "forwards pong messages from Gun to client", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      connected_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      pong_msg = {:gun_ws, gun_pid, stream_ref, {:pong, "server_pong"}}
      result = GunWebSocketHandler.handle_info(pong_msg, connected_state)
      
      assert {:reply, :ok, {:pong, "server_pong"}, ^connected_state} = result
    end

    test "handles WebSocket close from Gun", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      stream_ref = make_ref()
      
      connected_state = %{state | gun_pid: gun_pid, gun_stream_ref: stream_ref}
      
      close_msg = {:gun_ws, gun_pid, stream_ref, :close}
      result = GunWebSocketHandler.handle_info(close_msg, connected_state)
      
      assert {:stop, :normal, ^connected_state} = result
    end

    test "handles Gun connection down", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      
      connected_state = %{state | gun_pid: gun_pid}
      
      down_msg = {:gun_down, gun_pid, :http, :normal, []}
      result = GunWebSocketHandler.handle_info(down_msg, connected_state)
      
      assert {:stop, :normal, ^connected_state} = result
    end

    test "handles upgrade timeout when pending", %{state: state} do
      pending_state = %{state | upgrade_pending: true}
      
      result = GunWebSocketHandler.handle_info(:upgrade_timeout, pending_state)
      
      assert {:stop, :normal, ^pending_state} = result
    end

    test "ignores upgrade timeout when not pending", %{state: state} do
      complete_state = %{state | upgrade_pending: false}
      
      result = GunWebSocketHandler.handle_info(:upgrade_timeout, complete_state)
      
      assert {:ok, ^complete_state} = result
    end

    test "handles unexpected messages gracefully", %{state: state} do
      result = GunWebSocketHandler.handle_info(:unexpected_message, state)
      
      assert {:ok, ^state} = result
    end
  end

  describe "terminate/2" do
    test "closes Gun connection on termination", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      terminating_state = %{state | gun_pid: gun_pid}
      
      with_mock :gun, [:unstick],
        close: fn(_pid) -> :ok end do
        
        result = GunWebSocketHandler.terminate(:normal, terminating_state)
        
        assert result == :ok
        assert_called :gun.close(gun_pid)
      end
    end

    test "handles termination when no Gun connection exists", %{state: state} do
      result = GunWebSocketHandler.terminate(:normal, state)
      
      assert result == :ok
    end

    test "handles termination with error reason", %{state: state} do
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      terminating_state = %{state | gun_pid: gun_pid}
      
      with_mock :gun, [:unstick],
        close: fn(_pid) -> :ok end do
        
        result = GunWebSocketHandler.terminate({:error, :timeout}, terminating_state)
        
        assert result == :ok
        assert_called :gun.close(gun_pid)
      end
    end
  end

  describe "header preparation" do
    test "converts headers to charlist format for Gun", %{state: state} do
      headers = [
        {"authorization", "Bearer token123"},
        {"user-agent", "TestClient/1.0"},
        {"custom-header", "custom-value"}
      ]
      
      gun_state = %{state | headers: headers}
      gun_pid = spawn(fn -> :timer.sleep(1000) end)
      
      with_mock :gun, [:unstick],
        open: fn(_host, _port, _opts) -> {:ok, gun_pid} end,
        await_up: fn(_pid, _timeout) -> {:ok, :http} end,
        ws_upgrade: fn(_pid, _path, gun_headers) ->
          # Verify headers are converted to charlists
          expected_headers = [
            {~c"authorization", ~c"Bearer token123"},
            {~c"user-agent", ~c"TestClient/1.0"},
            {~c"custom-header", ~c"custom-value"}
          ]
          assert gun_headers == expected_headers
          make_ref()
        end do
        
        GunWebSocketHandler.init(gun_state)
      end
    end
  end
end