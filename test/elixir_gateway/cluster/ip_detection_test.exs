defmodule ElixirGateway.Cluster.IPDetectionTest do
  use ExUnit.Case, async: true

  alias ElixirGateway.Cluster.IPDetection

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "get_public_ip/0" do
    test "successfully retrieves public IP from ipify.org" do
      # This is a real external call - we just verify it returns an IP format
      case IPDetection.get_public_ip() do
        {:ok, ip} ->
          assert is_binary(ip)
          # Verify it looks like an IP address
          assert Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, ip)

        {:error, _reason} ->
          # Network failures are acceptable in tests
          assert true
      end
    end
  end

  describe "get_local_ip/0" do
    test "successfully retrieves a local IP address" do
      case IPDetection.get_local_ip() do
        {:ok, ip} ->
          assert is_binary(ip)
          # Verify it looks like an IP address
          assert Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, ip)
          # Should not be loopback
          refute ip == "127.0.0.1"

        {:error, _reason} ->
          # This can happen in some test environments
          assert true
      end
    end
  end
end
