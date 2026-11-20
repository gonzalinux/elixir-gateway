defmodule ElixirGateway.Cluster.DNSFailoverTest do
  use ExUnit.Case, async: false

  alias ElixirGateway.Cluster.DNSFailover

  setup do
    on_exit(fn ->
      if pid = Process.whereis(DNSFailover) do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  test "survives a health check when Cluster.Manager is unreachable" do
    refute Process.whereis(ElixirGateway.Cluster.Manager)

    {:ok, pid} =
      DNSFailover.start_link(
        domains: [],
        check_interval: :timer.minutes(10),
        failover_timeout: :timer.minutes(10)
      )

    send(pid, :check_health)

    # Give the GenServer a moment to process the message
    :timer.sleep(50)

    assert Process.alive?(pid)
    assert %{last_state: :failed} = DNSFailover.status()
  end

  describe "loggable_domains/1" do
    test "lists host.domain and provider without the DDNS password" do
      domains = [
        %{host: "@", domain: "example.com", password: "secret-namecheap-pass"},
        %{host: "garage", domain: "example.org", password: "cloudflare"}
      ]

      line = DNSFailover.loggable_domains(domains)

      assert line == "example.com (namecheap), garage.example.org (cloudflare)"
      refute line =~ "secret-namecheap-pass"
    end
  end
end
