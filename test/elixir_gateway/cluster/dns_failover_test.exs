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
end
