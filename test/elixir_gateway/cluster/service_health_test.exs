defmodule ElixirGateway.Cluster.ServiceHealthTest do
  # Not async: ServiceHealth is a single named process with a named ETS table,
  # shared by every test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirGateway.Cluster.ServiceHealth

  # The application already starts ServiceHealth, so these tests talk to that
  # running instance and pretend to be a peer node. No real cluster needed.

  setup do
    # A different fake peer per test, so tests never see each other's rows.
    peer = :"fake_peer_#{System.unique_integer([:positive])}@127.0.0.1"

    # Forget everything about the fake peer when the test ends.
    on_exit(fn -> send(ServiceHealth, {:nodedown, peer}) end)

    {:ok, peer: peer}
  end

  # Casts are asynchronous: GenServer.cast returns before the message is handled.
  # :sys.get_state/1 is a synchronous call, and a process handles its messages in
  # order, so once it returns every cast we sent before it has been processed.
  defp sync, do: :sys.get_state(ServiceHealth)

  describe "peer down list" do
    test "marks the listed domains of the peer as down", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["a.com", "b.com"]})
      sync()

      refute ServiceHealth.healthy?("a.com", peer)
      refute ServiceHealth.healthy?("b.com", peer)
      assert ServiceHealth.healthy?("c.com", peer)
    end

    test "replaces what we knew about the peer", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["a.com", "b.com"]})
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["b.com"]})
      sync()

      assert ServiceHealth.healthy?("a.com", peer)
      refute ServiceHealth.healthy?("b.com", peer)
    end

    test "does not affect the same domain on this node", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["a.com"]})
      sync()

      refute ServiceHealth.healthy?("a.com", peer)
      assert ServiceHealth.healthy?("a.com")
    end
  end

  describe "peer update" do
    test ":ko marks the domains as down", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_update, peer, ["a.com", "b.com"], :ko})
      sync()

      refute ServiceHealth.healthy?("a.com", peer)
      refute ServiceHealth.healthy?("b.com", peer)
    end

    test ":ok marks the domains as healthy again", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_update, peer, ["a.com", "b.com"], :ko})
      GenServer.cast(ServiceHealth, {:peer_update, peer, ["a.com", "b.com"], :ok})
      sync()

      assert ServiceHealth.healthy?("a.com", peer)
      assert ServiceHealth.healthy?("b.com", peer)
    end
  end

  describe "nodedown" do
    test "forgets every entry of that peer", %{peer: peer} do
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["a.com", "b.com"]})
      send(ServiceHealth, {:nodedown, peer})
      sync()

      assert ServiceHealth.healthy?("a.com", peer)
      assert ServiceHealth.healthy?("b.com", peer)
    end

    test "leaves other peers alone", %{peer: peer} do
      other = :"other_#{peer}"
      GenServer.cast(ServiceHealth, {:peer_down_list, peer, ["a.com"]})
      GenServer.cast(ServiceHealth, {:peer_down_list, other, ["a.com"]})
      send(ServiceHealth, {:nodedown, peer})
      sync()

      assert ServiceHealth.healthy?("a.com", peer)
      refute ServiceHealth.healthy?("a.com", other)

      send(ServiceHealth, {:nodedown, other})
    end
  end

  describe "check/2" do
    # Bypass starts a real HTTP server on a random port for each test.
    # We point the service's target at it and script how it answers.
    setup do
      bypass = Bypass.open()

      service = %{
        name: "test_service",
        target: "http://localhost:#{bypass.port}",
        health_path: "/health",
        health_domain: "health.example.com"
      }

      {:ok, bypass: bypass, service: service}
    end

    test "200 is healthy", %{bypass: bypass, service: service} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert ServiceHealth.check(service, 1_000) == :ok
    end

    test "any other 2xx is unhealthy", %{bypass: bypass, service: service} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      # capture_log swallows the warning check/2 logs, keeping the test output clean
      capture_log(fn -> assert ServiceHealth.check(service, 1_000) == :ko end)
    end

    test "500 is unhealthy and logs the reason", %{bypass: bypass, service: service} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      log = capture_log(fn -> assert ServiceHealth.check(service, 1_000) == :ko end)
      assert log =~ "Unhealthy service [test_service]"
    end

    test "a backend that is not listening is unhealthy", %{bypass: bypass, service: service} do
      # Closes the port: the request gets "connection refused"
      Bypass.down(bypass)

      capture_log(fn -> assert ServiceHealth.check(service, 1_000) == :ko end)
    end

    test "a backend slower than the timeout is unhealthy", %{bypass: bypass, service: service} do
      # stub (not expect): no assertion on how many requests arrive
      Bypass.stub(bypass, "GET", "/health", fn conn ->
        Process.sleep(300)
        Plug.Conn.resp(conn, 200, "ok")
      end)

      capture_log(fn -> assert ServiceHealth.check(service, 50) == :ko end)
    end

    test "uses the configured health path", %{bypass: bypass, service: service} do
      Bypass.expect_once(bypass, "GET", "/custom/status", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert ServiceHealth.check(%{service | health_path: "/custom/status"}, 1_000) == :ok
    end

    test "sends health_domain as the Host header", %{bypass: bypass, service: service} do
      Bypass.expect_once(bypass, "GET", "/health", fn conn ->
        assert Plug.Conn.get_req_header(conn, "host") == ["health.example.com"]
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert ServiceHealth.check(service, 1_000) == :ok
    end
  end

  describe "update_health/2" do
    defp service(health), do: %{health: health, ok_counter: 0, ko_counter: 0}

    # Feeds a list of check results into update_health/2, one after another
    defp feed(service, results),
      do: Enum.reduce(results, service, &ServiceHealth.update_health(&2, &1))

    test "a healthy service stays up for 3 failures in a row" do
      updated = feed(service(:ok), [:ko, :ko, :ko])

      assert updated.health == :ok
      assert updated.ko_counter == 3
    end

    test "a healthy service goes down on the 4th failure in a row" do
      updated = feed(service(:ok), [:ko, :ko, :ko, :ko])

      assert updated.health == :ko
      assert updated.ko_counter == 0
    end

    test "a success resets the failure count while up" do
      updated = feed(service(:ok), [:ko, :ko, :ko, :ok, :ko, :ko, :ko])

      assert updated.health == :ok
      assert updated.ko_counter == 3
    end

    test "a down service stays down for 2 successes in a row" do
      updated = feed(service(:ko), [:ok, :ok])

      assert updated.health == :ko
      assert updated.ok_counter == 2
    end

    test "a down service comes back up on the 3rd success in a row" do
      updated = feed(service(:ko), [:ok, :ok, :ok])

      assert updated.health == :ok
      assert updated.ok_counter == 0
    end

    test "a failure resets the success count while down" do
      updated = feed(service(:ko), [:ok, :ok, :ko, :ok, :ok])

      assert updated.health == :ko
      assert updated.ok_counter == 2
    end
  end

  describe "check loop" do
    # These tests restart the application's ServiceHealth with one configured service
    # pointing at a Bypass backend, and short intervals so it flips quickly.
    setup do
      bypass = Bypass.open()

      # How the fake backend answers. Kept in :persistent_term (not an Agent) because
      # checks can still hit Bypass after the test process exits, until on_exit runs.
      backend = {__MODULE__, bypass.port}
      :persistent_term.put(backend, %{status: 200, delay: 0})

      Bypass.stub(bypass, "GET", "/health", fn conn ->
        %{status: code, delay: ms} = :persistent_term.get(backend)
        Process.sleep(ms)
        Plug.Conn.resp(conn, code, "")
      end)

      original_gateway = Application.get_env(:elixirgateway, :gateway)
      original_health = Application.get_env(:elixirgateway, :health)

      health_services = %{
        "loop_test" => %{
          name: "loop_test",
          target: "http://localhost:#{bypass.port}",
          domains: ["loop.test"],
          health_path: "/health",
          health_domain: "loop.test"
        }
      }

      Application.put_env(
        :elixirgateway,
        :gateway,
        Keyword.put(original_gateway || [], :health, health_services)
      )

      Application.put_env(:elixirgateway, :health, ping_interval_ms: 20, timeout_ms: 500)
      restart_service_health()

      on_exit(fn ->
        restore_env(:gateway, original_gateway)
        restore_env(:health, original_health)
        restart_service_health()
        :persistent_term.erase(backend)
      end)

      {:ok, backend: backend}
    end

    defp restart_service_health do
      :ok = Supervisor.terminate_child(ElixirGateway.Supervisor, ServiceHealth)
      {:ok, _pid} = Supervisor.restart_child(ElixirGateway.Supervisor, ServiceHealth)
    end

    defp restore_env(key, nil), do: Application.delete_env(:elixirgateway, key)
    defp restore_env(key, value), do: Application.put_env(:elixirgateway, key, value)

    # Polls until fun returns true, or fails after ~2s
    defp eventually(fun, attempts \\ 100) do
      cond do
        fun.() -> true
        attempts == 0 -> flunk("condition never became true")
        true -> Process.sleep(20) && eventually(fun, attempts - 1)
      end
    end

    defp set_backend(backend, changes),
      do: :persistent_term.put(backend, Map.merge(:persistent_term.get(backend), changes))

    test "a failing backend goes down, and comes back up when it recovers", %{backend: backend} do
      eventually(fn -> ServiceHealth.statuses() == [{"loop_test", :ok}] end)
      assert ServiceHealth.healthy?("loop.test")

      capture_log(fn ->
        set_backend(backend, %{status: 500})
        eventually(fn -> not ServiceHealth.healthy?("loop.test") end)
        assert ServiceHealth.statuses() == [{"loop_test", :ko}]

        set_backend(backend, %{status: 200})
        eventually(fn -> ServiceHealth.healthy?("loop.test") end)
      end)

      assert ServiceHealth.statuses() == [{"loop_test", :ok}]
    end

    test "the GenServer stays responsive while a check is in flight", %{backend: backend} do
      # Every check now takes 300ms; before checks ran in tasks, calls would wait for them
      set_backend(backend, %{delay: 300})
      Process.sleep(100)

      {micros, statuses} = :timer.tc(fn -> ServiceHealth.statuses() end)

      assert statuses == [{"loop_test", :ok}]
      assert micros < 100_000
    end

    test "only one check per service is in flight at a time", %{backend: backend} do
      set_backend(backend, %{delay: 200})
      Process.sleep(500)

      assert map_size(:sys.get_state(ServiceHealth).tasks) <= 1
    end
  end

  test "unexpected messages do not crash the process" do
    pid = Process.whereis(ServiceHealth)

    GenServer.cast(ServiceHealth, :something_unexpected)
    send(ServiceHealth, :something_unexpected)
    sync()

    assert Process.whereis(ServiceHealth) == pid
  end
end
