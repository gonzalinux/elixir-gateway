defmodule ElixirGatewayWeb.Plugs.HttpsRedirectPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ElixirGatewayWeb.Plugs.HttpsRedirectPlug

  defp call(conn, force_https) do
    conn
    |> assign(:force_https, force_https)
    |> assign(:original_host, conn.host)
    |> HttpsRedirectPlug.call([])
  end

  describe "HTTP requests with force_https: true" do
    test "redirects to HTTPS with 301" do
      conn = conn(:get, "http://example.com/some/path") |> call(true)

      assert conn.status == 301
      assert conn.halted
      assert get_resp_header(conn, "location") == ["https://example.com/some/path"]
    end

    test "preserves query string in redirect" do
      conn = conn(:get, "http://example.com/path?foo=bar&baz=qux") |> call(true)

      assert get_resp_header(conn, "location") == ["https://example.com/path?foo=bar&baz=qux"]
    end

    test "uses original_host assign for redirect target" do
      conn =
        conn(:get, "http://ignored.com/path")
        |> assign(:force_https, true)
        |> assign(:original_host, "actual.com")
        |> HttpsRedirectPlug.call([])

      assert get_resp_header(conn, "location") == ["https://actual.com/path"]
    end

    test "falls back to conn.host when original_host not set" do
      conn =
        conn(:get, "http://example.com/path")
        |> assign(:force_https, true)
        |> HttpsRedirectPlug.call([])

      assert get_resp_header(conn, "location") == ["https://example.com/path"]
    end
  end

  describe "requests that should not be redirected" do
    test "does not redirect when force_https is false" do
      conn = conn(:get, "http://example.com/path") |> call(false)

      refute conn.halted
      assert conn.status != 301
    end

    test "does not redirect HTTPS requests" do
      conn = conn(:get, "https://example.com/path") |> call(true)

      refute conn.halted
    end

    test "does not redirect when x-forwarded-proto is https" do
      conn =
        conn(:get, "http://example.com/path")
        |> put_req_header("x-forwarded-proto", "https")
        |> call(true)

      refute conn.halted
    end
  end

  describe "edge cases" do
    test "redirect with root path" do
      conn = conn(:get, "http://example.com/") |> call(true)

      assert get_resp_header(conn, "location") == ["https://example.com/"]
    end

    test "redirect with no query string has no trailing question mark" do
      conn = conn(:get, "http://example.com/path") |> call(true)

      [location] = get_resp_header(conn, "location")
      refute String.ends_with?(location, "?")
    end
  end
end
