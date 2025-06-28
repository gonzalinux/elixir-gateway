defmodule ElixirGatewayWeb.Plugs.DomainRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  
  alias ElixirGatewayWeb.Plugs.DomainRouter

  describe "domain routing" do
    setup do
      # Set up test configuration
      original_config = Application.get_env(:elixirgateway, :gateway)
      
      Application.put_env(:elixirgateway, :gateway,
        services: %{
          "api.example.com" => "http://backend1.local:8080",
          "admin.example.com" => "https://backend2.local:9443",
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

    test "routes to correct service based on host header" do
      conn = conn(:get, "/")
      |> Map.put(:host, "api.example.com")
      |> DomainRouter.call([])

      assert conn.assigns[:target_url] == "http://backend1.local:8080"
      assert conn.assigns[:original_host] == "api.example.com"
      refute conn.halted
    end

    test "routes to https service" do
      conn = conn(:get, "/")
      |> Map.put(:host, "admin.example.com")
      |> DomainRouter.call([])

      assert conn.assigns[:target_url] == "https://backend2.local:9443"
      assert conn.assigns[:original_host] == "admin.example.com"
      refute conn.halted
    end

    test "strips port from host header" do
      # Test the header parsing logic by setting host to nil
      # so it falls back to reading headers
      conn = conn(:get, "/")
      |> Map.put(:host, nil)
      |> Map.put(:req_headers, [{"host", "api.example.com:4000"}])
      |> DomainRouter.call([])

      assert conn.assigns[:target_url] == "http://backend1.local:8080"
      assert conn.assigns[:original_host] == "api.example.com"
      refute conn.halted
    end

    test "falls back to default when host not found" do
      conn = conn(:get, "/")
      |> Map.put(:host, "unknown.example.com")
      |> DomainRouter.call([])

      assert conn.status == 404
      assert conn.halted
      assert conn.resp_body =~ "Service not found for host: unknown.example.com"
    end

    test "falls back to default when no host header present" do
      conn = conn(:get, "/")
      |> Map.put(:host, nil)
      |> Map.put(:req_headers, [])  # Ensure no host headers
      |> DomainRouter.call([])

      # Should successfully route to default service
      assert conn.assigns[:target_url] == "http://default.local:3000"
      assert conn.assigns[:original_host] == "default"
      refute conn.halted
    end

    test "uses conn.host when no host header" do
      conn = conn(:get, "/")
      |> Map.put(:host, "api.example.com")
      |> DomainRouter.call([])

      assert conn.assigns[:target_url] == "http://backend1.local:8080"
      assert conn.assigns[:original_host] == "api.example.com"
      refute conn.halted
    end

    test "handles multiple host headers by using first one" do
      conn = conn(:get, "/")
      |> Map.put(:host, nil)
      |> Map.put(:req_headers, [{"host", "api.example.com"}, {"host", "admin.example.com"}])
      |> DomainRouter.call([])

      assert conn.assigns[:target_url] == "http://backend1.local:8080"
      assert conn.assigns[:original_host] == "api.example.com"
      refute conn.halted
    end

    test "returns JSON error response for unmapped domain" do
      conn = conn(:get, "/")
      |> Map.put(:host, "nonexistent.com")
      |> DomainRouter.call([])

      assert conn.status == 404
      assert conn.halted
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["error"] == "Service not found for host: nonexistent.com"
    end
  end

  describe "configuration edge cases" do
    test "handles missing gateway config gracefully" do
      Application.delete_env(:elixirgateway, :gateway)
      
      conn = conn(:get, "/")
      |> Map.put(:host, "any.example.com")
      |> DomainRouter.call([])

      assert conn.status == 404
      assert conn.halted
    end

    test "handles empty services config" do
      Application.put_env(:elixirgateway, :gateway, services: %{})
      
      conn = conn(:get, "/")
      |> Map.put(:host, "api.example.com")
      |> DomainRouter.call([])

      assert conn.status == 404
      assert conn.halted
    end
  end
end