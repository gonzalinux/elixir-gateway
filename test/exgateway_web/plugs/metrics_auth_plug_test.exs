defmodule ElixirGatewayWeb.Plugs.MetricsAuthPlugTest do
  use ElixirGatewayWeb.ConnCase, async: true
  
  alias ElixirGatewayWeb.Plugs.MetricsAuthPlug

  describe "private network access control" do
    test "allows access from IPv4 private network 10.0.0.0/8", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 0, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from IPv4 private network 192.168.0.0/16", %{conn: conn} do
      conn = %{conn | remote_ip: {192, 168, 1, 100}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from IPv4 private network 172.16.0.0/12", %{conn: conn} do
      # Test various IPs in the 172.16-31.x.x range
      test_ips = [
        {172, 16, 0, 1},    # Start of range
        {172, 20, 1, 1},    # Middle of range
        {172, 31, 255, 255} # End of range
      ]
      
      Enum.each(test_ips, fn ip ->
        conn = %{conn | remote_ip: ip}
        conn = MetricsAuthPlug.call(conn, [])
        refute conn.halted
      end)
    end

    test "allows access from localhost 127.0.0.0/8", %{conn: conn} do
      test_ips = [
        {127, 0, 0, 1},     # Standard localhost
        {127, 1, 1, 1},     # Other 127.x addresses
        {127, 255, 255, 255}
      ]
      
      Enum.each(test_ips, fn ip ->
        conn = %{conn | remote_ip: ip}
        conn = MetricsAuthPlug.call(conn, [])
        refute conn.halted
      end)
    end

    test "allows access from link-local 169.254.0.0/16", %{conn: conn} do
      conn = %{conn | remote_ip: {169, 254, 1, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from Docker default bridge 172.17.0.0/16", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 17, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end
  end

  describe "public network access control" do
    test "blocks access from public IPv4 addresses", %{conn: conn} do
      public_ips = [
        {8, 8, 8, 8},       # Google DNS
        {1, 1, 1, 1},       # Cloudflare DNS
        {208, 67, 222, 222}, # OpenDNS
        {172, 15, 1, 1},    # Just outside private range
        {172, 32, 1, 1},    # Just outside private range
        {193, 168, 1, 1},   # Similar to 192.168 but public
        {172, 16, 0, 0}     # Edge case: exactly 172.16.0.0
      ]
      
      Enum.each(public_ips, fn ip ->
        conn = %{conn | remote_ip: ip}
        conn = MetricsAuthPlug.call(conn, [])
        
        assert conn.halted
        assert conn.status == 403
        assert get_resp_header(conn, "content-type") == ["text/plain"]
        assert conn.resp_body =~ "Forbidden: Metrics endpoint restricted to private networks"
        assert conn.resp_body =~ :inet.ntoa(ip) |> to_string()
      end)
    end

    test "blocks 172.15.x.x (just before private range)", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 15, 255, 255}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end

    test "blocks 172.32.x.x (just after private range)", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 32, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "IPv6 access control" do
    test "allows access from IPv6 localhost ::1", %{conn: conn} do
      conn = %{conn | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from IPv6 unique local fc00::/7", %{conn: conn} do
      conn = %{conn | remote_ip: {0xFC00, 0, 0, 0, 0, 0, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from IPv6 unique local fd00::/8", %{conn: conn} do
      conn = %{conn | remote_ip: {0xFD00, 0, 0, 0, 0, 0, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "allows access from IPv6 link-local fe80::/10", %{conn: conn} do
      conn = %{conn | remote_ip: {0xFE80, 0, 0, 0, 0, 0, 0, 1}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "blocks access from IPv6 public addresses", %{conn: conn} do
      public_ipv6_addresses = [
        {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}, # Google DNS
        {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}, # Cloudflare DNS
        {0x2001, 0xdb8, 0, 0, 0, 0, 0, 1}             # Documentation prefix
      ]
      
      Enum.each(public_ipv6_addresses, fn ip ->
        conn = %{conn | remote_ip: ip}
        conn = MetricsAuthPlug.call(conn, [])
        
        assert conn.halted
        assert conn.status == 403
        assert conn.resp_body =~ "Forbidden: Metrics endpoint restricted to private networks"
      end)
    end
  end

  describe "edge cases and error handling" do
    test "handles malformed IP addresses gracefully", %{conn: conn} do
      # Test with invalid IP format
      conn = %{conn | remote_ip: :invalid_ip}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end

    test "handles missing remote_ip", %{conn: conn} do
      conn = %{conn | remote_ip: nil}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end

    test "response includes IP address in error message", %{conn: conn} do
      test_ip = {8, 8, 8, 8}
      conn = %{conn | remote_ip: test_ip}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "8.8.8.8"
    end

    test "plug can be called with options", %{conn: conn} do
      conn = %{conn | remote_ip: {192, 168, 1, 1}}
      
      # Test that options parameter doesn't break the plug
      conn = MetricsAuthPlug.call(conn, some_option: :value)
      
      refute conn.halted
    end
  end

  describe "boundary testing for 172.16.0.0/12" do
    test "172.16.0.0 is included in private range", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 16, 0, 0}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "172.31.255.255 is included in private range", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 31, 255, 255}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      refute conn.halted
    end

    test "172.15.255.255 is excluded from private range", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 15, 255, 255}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end

    test "172.32.0.0 is excluded from private range", %{conn: conn} do
      conn = %{conn | remote_ip: {172, 32, 0, 0}}
      
      conn = MetricsAuthPlug.call(conn, [])
      
      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "init function" do
    test "init returns options unchanged" do
      opts = [some: :option]
      assert MetricsAuthPlug.init(opts) == opts
    end

    test "init handles empty options" do
      assert MetricsAuthPlug.init([]) == []
    end
  end
end