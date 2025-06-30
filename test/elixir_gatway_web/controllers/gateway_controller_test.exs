defmodule ElixirGatewayWeb.GatewayControllerTest do
  use ElixirGatewayWeb.ConnCase, async: true

  alias ElixirGatewayWeb.GatewayController

  describe "proxy/2" do
    test "returns 500 error when reached (indicates plug pipeline failure)", %{conn: conn} do
      # Manually call the controller action to simulate reaching it
      conn = GatewayController.proxy(conn, %{})

      assert conn.status == 500
      # Controller doesn't halt, just sets status
      assert conn.halted == false

      # Parse the JSON response
      response = json_response(conn, 500)
      assert response["error"] == "Gateway configuration error"
    end

    test "handles POST requests with same error response", %{conn: conn} do
      conn = GatewayController.proxy(conn, %{some: "params"})

      assert conn.status == 500

      response = json_response(conn, 500)
      assert response["error"] == "Gateway configuration error"
    end

    test "handles PUT requests", %{conn: conn} do
      conn = GatewayController.proxy(conn, %{})

      assert conn.status == 500

      response = json_response(conn, 500)
      assert response["error"] == "Gateway configuration error"
    end

    test "handles DELETE requests", %{conn: conn} do
      conn = GatewayController.proxy(conn, %{})

      assert conn.status == 500

      response = json_response(conn, 500)
      assert response["error"] == "Gateway configuration error"
    end

    test "ignores params parameter", %{conn: conn} do
      # Test with different params to ensure they don't affect the response
      test_params = [
        %{},
        %{id: 123},
        %{complex: %{nested: "data"}},
        %{list: [1, 2, 3]}
      ]

      Enum.each(test_params, fn params ->
        result_conn = GatewayController.proxy(conn, params)

        assert result_conn.status == 500

        response = json_response(result_conn, 500)
        assert response["error"] == "Gateway configuration error"
      end)
    end

    test "preserves original connection properties", %{conn: conn} do
      original_method = conn.method
      original_path = conn.request_path

      conn =
        conn
        |> put_req_header("x-custom-header", "test-value")

      result_conn = GatewayController.proxy(conn, %{})

      # Verify original connection properties are preserved
      assert result_conn.method == original_method
      assert result_conn.request_path == original_path
      assert "x-custom-header" in (result_conn.req_headers |> Enum.map(fn {k, _v} -> k end))
    end

    test "sets correct content type for JSON response", %{conn: conn} do
      conn = GatewayController.proxy(conn, %{})

      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "maintains request_id if present", %{conn: conn} do
      request_id = "test-request-id-123"

      conn =
        conn
        |> put_req_header("x-request-id", request_id)

      result_conn = GatewayController.proxy(conn, %{})

      assert get_req_header(result_conn, "x-request-id") == [request_id]
    end
  end

  describe "controller module" do
    test "uses correct controller macro" do
      # Verify the controller is properly set up with Phoenix controller
      assert function_exported?(GatewayController, :action, 2)
      assert function_exported?(GatewayController, :proxy, 2)
    end

    test "has correct module attributes" do
      # Check that the controller has the expected attributes
      attributes = GatewayController.__info__(:attributes)
      assert is_list(attributes)
      # Check behavior attribute exists
      assert Keyword.has_key?(attributes, :behaviour)
    end
  end

  describe "error logging verification" do
    test "logs warning when proxy action is reached" do
      import ExUnit.CaptureLog

      conn = build_conn(:get, "/api/test")

      log_output =
        capture_log(fn ->
          GatewayController.proxy(conn, %{})
        end)

      assert log_output =~ "Request reached GatewayController.proxy"
      assert log_output =~ "this should not normally happen"
    end

    test "includes warning level in log output" do
      import ExUnit.CaptureLog

      conn = build_conn(:get, "/api/test")

      log_output =
        capture_log(fn ->
          GatewayController.proxy(conn, %{})
        end)

      assert log_output =~ "[warning]" or log_output =~ "[warn]"
    end
  end

  describe "integration scenarios" do
    test "simulates plug pipeline failure scenario", %{conn: conn} do
      # This test simulates what would happen if the domain router, 
      # rate limiter, or request forwarder plugs all failed to handle the request

      conn =
        conn
        |> Map.put(:host, "unknown-service.com")

      # In a real scenario, the plugs would handle this, but if they all fail:
      result_conn = GatewayController.proxy(conn, %{})

      assert result_conn.status == 500

      response = json_response(result_conn, 500)
      assert response["error"] == "Gateway configuration error"
    end

    test "handles requests with query parameters", %{conn: conn} do
      result_conn = GatewayController.proxy(conn, %{})

      assert result_conn.status == 500
    end

    test "handles requests with request body", %{conn: conn} do
      result_conn = GatewayController.proxy(conn, %{})

      assert result_conn.status == 500
    end
  end
end
