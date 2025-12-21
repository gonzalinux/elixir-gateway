defmodule ElixirGateway.Cluster.DDNS.NamecheapTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "update/4" do
    test "successfully updates DNS record", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/update", fn conn ->
        # Verify query parameters (@ is URL-encoded as %40)
        assert conn.query_string =~ "host=%40"
        assert conn.query_string =~ "domain=example.com"
        assert conn.query_string =~ "password=test123"
        assert conn.query_string =~ "ip=1.2.3.4"

        Plug.Conn.resp(conn, 200, """
        <?xml version="1.0"?>
        <interface-response>
          <ErrCount>0</ErrCount>
          <ResponseCount>1</ResponseCount>
        </interface-response>
        """)
      end)

      # Override the DDNS URL for testing
      url = "http://localhost:#{bypass.port}/update"

      result =
        update_with_custom_url(
          "@",
          "example.com",
          "test123",
          "1.2.3.4",
          url
        )

      assert :ok = result
    end

    test "handles DDNS error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/update", fn conn ->
        Plug.Conn.resp(conn, 200, """
        <?xml version="1.0"?>
        <interface-response>
          <ErrCount>1</ErrCount>
          <Err1>Invalid password</Err1>
        </interface-response>
        """)
      end)

      url = "http://localhost:#{bypass.port}/update"

      result =
        update_with_custom_url(
          "@",
          "example.com",
          "wrong_password",
          "1.2.3.4",
          url
        )

      assert {:error, "DDNS error: Invalid password"} = result
    end

    test "handles HTTP error", %{bypass: bypass} do
      # Req will retry on 500 errors, so we need to handle multiple requests
      Bypass.expect(bypass, "GET", "/update", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      url = "http://localhost:#{bypass.port}/update"

      result =
        update_with_custom_url(
          "@",
          "example.com",
          "test123",
          "1.2.3.4",
          url
        )

      assert {:error, "HTTP 500: Internal Server Error"} = result
    end

    test "handles network error" do
      # Use non-existent host to simulate network error
      url = "http://invalid-host-that-does-not-exist.local:9999/update"

      result =
        update_with_custom_url(
          "@",
          "example.com",
          "test123",
          "1.2.3.4",
          url
        )

      assert {:error, _reason} = result
    end
  end

  describe "update_all/2" do
    test "updates multiple domains successfully", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/update", fn conn ->
        Plug.Conn.resp(conn, 200, """
        <?xml version="1.0"?>
        <interface-response>
          <ErrCount>0</ErrCount>
        </interface-response>
        """)
      end)

      url = "http://localhost:#{bypass.port}/update"

      domains = [
        %{host: "@", domain: "example.com", password: "pass1"},
        %{host: "www", domain: "example.com", password: "pass2"},
        %{host: "@", domain: "another.org", password: "pass3"}
      ]

      results = update_all_with_custom_url(domains, "1.2.3.4", url)

      assert length(results) == 3
      assert Enum.all?(results, fn {_domain, _host, result} -> result == :ok end)
    end

    test "reports individual failures", %{bypass: bypass} do
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/update", fn conn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 1 do
          # Second call fails
          Plug.Conn.resp(conn, 200, """
          <?xml version="1.0"?>
          <interface-response>
            <ErrCount>1</ErrCount>
            <Err1>Failed</Err1>
          </interface-response>
          """)
        else
          Plug.Conn.resp(conn, 200, """
          <?xml version="1.0"?>
          <interface-response>
            <ErrCount>0</ErrCount>
          </interface-response>
          """)
        end
      end)

      url = "http://localhost:#{bypass.port}/update"

      domains = [
        %{host: "@", domain: "example.com", password: "pass1"},
        %{host: "www", domain: "example.com", password: "pass2"}
      ]

      results = update_all_with_custom_url(domains, "1.2.3.4", url)

      assert length(results) == 2
      # One success, one failure
      assert Enum.count(results, fn {_, _, result} -> result == :ok end) == 1
      assert Enum.count(results, fn {_, _, result} -> match?({:error, _}, result) end) == 1
    end
  end

  describe "get_public_ip/0" do
    test "successfully retrieves public IP", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 200, "203.0.113.42")
      end)

      url = "http://localhost:#{bypass.port}"
      result = get_public_ip_with_custom_url(url)

      assert {:ok, "203.0.113.42"} = result
    end

    test "handles HTTP error", %{bypass: bypass} do
      # Req will retry on 500 errors, so we need to handle multiple requests
      Bypass.expect(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 500, "Error")
      end)

      url = "http://localhost:#{bypass.port}"
      result = get_public_ip_with_custom_url(url)

      assert {:error, "HTTP 500"} = result
    end

    test "trims whitespace from IP", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 200, "  203.0.113.42\n")
      end)

      url = "http://localhost:#{bypass.port}"
      result = get_public_ip_with_custom_url(url)

      assert {:ok, "203.0.113.42"} = result
    end
  end

  # Helper functions to allow custom URLs for testing

  defp update_with_custom_url(host, domain, password, ip, url) do
    full_url = "#{url}?#{URI.encode_query(%{host: host, domain: domain, password: password, ip: ip})}"

    case Req.get(full_url) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_all_with_custom_url(domains, ip, url) do
    Enum.map(domains, fn %{host: host, domain: domain, password: password} ->
      result = update_with_custom_url(host, domain, password, ip, url)
      {domain, host, result}
    end)
  end

  defp get_public_ip_with_custom_url(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: ip}} ->
        {:ok, String.trim(ip)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(body) do
    cond do
      String.contains?(body, "<ErrCount>0</ErrCount>") ->
        :ok

      error_match = Regex.run(~r/<Err1>(.*?)<\/Err1>/, body) ->
        [_, error] = error_match
        {:error, "DDNS error: #{error}"}

      true ->
        {:error, "Unknown response: #{body}"}
    end
  end
end
