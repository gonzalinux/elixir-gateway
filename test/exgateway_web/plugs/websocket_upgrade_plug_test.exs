defmodule ElixirGatewayWeb.Plugs.WebSocketUpgradePlugTest do
  use ElixirGatewayWeb.ConnCase, async: true
  import Mock
  
  alias ElixirGatewayWeb.Plugs.WebSocketUpgradePlug

  setup do
    # Set up test configuration
    original_config = Application.get_env(:elixirgateway, :gateway)
    
    Application.put_env(:elixirgateway, :gateway,
      services: %{
        "ws.example.com" => "http://backend.local:8080",
        "secure-ws.example.com" => "https://backend.local:9443",
        "default" => "http://default.local:3000"
      }
    )
    
    on_exit(fn ->
      if original_config do
        Application.put_env(:elixirgateway, :gateway, original_config)
      else
        Application.delete_env(:elixirgateway, :gateway)
      end
    end)
    
    :ok
  end

  describe "WebSocket detection" do
    test "detects valid WebSocket upgrade request", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "Upgrade")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-version", "13")
        |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      # Mock WebSockAdapter.upgrade to prevent actual upgrade
      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, _state, _opts) -> 
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        
        assert conn.halted
        assert_called WebSockAdapter.upgrade(:_, ElixirGatewayWeb.GunWebSocketHandler, :_, :_)
      end
    end

    test "ignores non-WebSocket requests", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("accept", "text/html")
        |> Map.put(:host, "ws.example.com")
        |> WebSocketUpgradePlug.call([])

      refute conn.halted
    end

    test "detects WebSocket upgrade with case-insensitive headers", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "WebSocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, _state, _opts) -> 
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        
        assert conn.halted
      end
    end

    test "ignores upgrade without websocket", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "h2c")
        |> Map.put(:host, "ws.example.com")
        |> WebSocketUpgradePlug.call([])

      refute conn.halted
    end

    test "ignores websocket without upgrade connection", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "keep-alive")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> WebSocketUpgradePlug.call([])

      refute conn.halted
    end
  end

  describe "service mapping" do
    test "maps WebSocket request to correct backend service", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "token=abc123")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, handler, state, opts) ->
          assert handler == ElixirGatewayWeb.GunWebSocketHandler
          assert state.target_url == "ws://backend.local:8080/socket?token=abc123"
          assert state.host == "ws.example.com"
          assert state.path == "/socket?token=abc123"
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end

    test "converts HTTPS backend to WSS WebSocket URL", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "secure-ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          assert state.target_url == "wss://backend.local:9443/socket?"
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end

    test "returns 404 for unmapped host", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "unknown.example.com")
        |> Map.put(:request_path, "/socket")
        |> WebSocketUpgradePlug.call([])

      assert conn.status == 404
      assert conn.halted
      assert conn.resp_body == "Service not found"
      assert get_resp_header(conn, "content-type") == ["text/plain"]
    end
  end

  describe "header transformation" do
    test "transforms headers for backend service", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("authorization", "Bearer token123")
        |> put_req_header("user-agent", "Mozilla/5.0")
        |> put_req_header("origin", "https://frontend.example.com")
        |> put_req_header("cookie", "session_id=abc123")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:port, 4000)
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          headers = state.headers
          
          # Should include authorization and user-agent
          assert Enum.any?(headers, fn {name, value} -> 
            name == "authorization" && value == "Bearer token123" 
          end)
          assert Enum.any?(headers, fn {name, value} -> 
            name == "user-agent" && value == "Mozilla/5.0" 
          end)
          
          # Should set host to target backend
          assert Enum.any?(headers, fn {name, value} -> 
            name == "host" && value == "backend.local:8080" 
          end)
          
          # Should preserve original origin
          assert Enum.any?(headers, fn {name, value} -> 
            name == "origin" && value == "https://frontend.example.com" 
          end)
          
          # Should preserve cookies
          assert Enum.any?(headers, fn {name, value} -> 
            name == "cookie" && value == "session_id=abc123" 
          end)
          
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end

    test "handles missing headers gracefully", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:port, 4000)
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          headers = state.headers
          
          # Should still have host and origin headers
          assert Enum.any?(headers, fn {name, _value} -> name == "host" end)
          assert Enum.any?(headers, fn {name, _value} -> name == "origin" end)
          
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end

    test "filters out empty header values", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("authorization", "")  # Empty value should be filtered
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          headers = state.headers
          
          # Should not include empty authorization header
          refute Enum.any?(headers, fn {name, value} -> 
            name == "authorization" && value == "" 
          end)
          
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end
  end

  describe "path and query handling" do
    test "preserves request path and query string", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/api/v1/socket")
        |> Map.put(:query_string, "room=general&auth=token123")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          assert state.target_url == "ws://backend.local:8080/api/v1/socket?room=general&auth=token123"
          assert state.path == "/api/v1/socket?room=general&auth=token123"
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end

    test "handles empty query string", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          assert state.target_url == "ws://backend.local:8080/socket?"
          assert state.path == "/socket?"
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end
  end

  describe "configuration edge cases" do
    test "handles missing gateway config", %{conn: conn} do
      Application.delete_env(:elixirgateway, :gateway)
      
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> WebSocketUpgradePlug.call([])

      assert conn.status == 404
      assert conn.halted
    end

    test "handles empty services config", %{conn: conn} do
      Application.put_env(:elixirgateway, :gateway, services: %{})
      
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> WebSocketUpgradePlug.call([])

      assert conn.status == 404
      assert conn.halted
    end
  end

  describe "state preparation" do
    test "includes all required state for WebSocket handler", %{conn: conn} do
      conn = 
        conn
        |> put_req_header("connection", "upgrade")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/socket")
        |> Map.put(:query_string, "test=true")

      with_mock WebSockAdapter, [:passthrough], 
        upgrade: fn(conn, _handler, state, _opts) ->
          assert state.target_url == "ws://backend.local:8080/socket?test=true"
          assert state.host == "ws.example.com"
          assert state.target_host == "backend.local:8080"
          assert state.path == "/socket?test=true"
          assert is_list(state.headers)
          
          conn |> halt()
        end do
        
        conn = WebSocketUpgradePlug.call(conn, [])
        assert conn.halted
      end
    end
  end
end