defmodule ElixirGateway.Cluster.ServiceHealth do
  require Logger

  use GenServer

  @health_table :elixirgateway_service_health
  @default_timeout_ms 500
  @default_ping_interval_ms 1500
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :ets.new(@health_table, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    config = Application.get_env(:elixirgateway, :health, [])

    mixed_config = %{
      timeout_ms: Keyword.get(config, :timeout_ms, @default_timeout_ms),
      ping_interval_ms: Keyword.get(config, :ping_interval_ms, @default_ping_interval_ms)
    }

    services =
      ElixirGateway.ConfigLoader.get_health_services()
      |> Enum.map(fn {name, service} ->
        {name, Map.merge(service, %{health: :ok, ko_counter: 0, ok_counter: 0})}
      end)
      |> Map.new()

    domain_to_service =
      services
      |> Enum.flat_map(fn {name, service} ->
        service.domains
        |> Enum.map(fn domain -> {domain, name} end)
      end)
      |> Map.new()

    services
    |> Enum.each(fn {name, _service} ->
      Process.send_after(self(), {:check, name}, mixed_config.ping_interval_ms)
    end)

    :net_kernel.monitor_nodes(true)
    GenServer.abcast(Node.list(), __MODULE__, {:sync_request, node()})
    {:ok, %{config: mixed_config, services: services, domain_to_service: domain_to_service}}
  end

  @impl true
  def handle_call(:statuses, _from, state) do
    {:reply, Enum.map(state.services, fn {name, s} -> {name, s.health} end), state}
  end

  @impl true
  def handle_cast({:peer_down_list, peer, domains}, state) do
    :ets.match_delete(@health_table, {{peer, :_}, :_})
    Enum.each(domains, fn domain -> :ets.insert(@health_table, {{peer, domain}, :ko}) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_request, peer}, state) do
    GenServer.cast({__MODULE__, peer}, {:peer_down_list, node(), down_domains(state)})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:peer_update, peer, domains, health}, state) do
    domains
    |> Enum.each(fn domain ->
      case health do
        :ok ->
          :ets.delete(@health_table, {peer, domain})

        :ko ->
          :ets.insert(@health_table, {{peer, domain}, :ko})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_unhealthy, host_key}, state) do
    with {:ok, name} <- Map.fetch(state.domain_to_service, host_key) do
      service = state.services[name]
      service_updated = update_health(service, :ko)
      save_update(service, service_updated)
      {:noreply, put_in(state.services[name], service_updated)}
    else
      :error -> {:noreply, state}
    end
  end

  @impl true
  def handle_cast(msg, state) do
    Logger.debug("ServiceHealth: ignoring unexpected cast #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, peer}, state) do
    GenServer.cast({__MODULE__, peer}, {:peer_down_list, node(), down_domains(state)})
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, peer}, state) do
    :ets.match_delete(@health_table, {{peer, :_}, :_})
    {:noreply, state}
  end

  @impl true
  def handle_info({:check, name}, state) do
    service = state.services[name]

    health = check(service, state.config.timeout_ms)

    service_updated = update_health(service, health)

    save_update(service, service_updated)

    Process.send_after(self(), {:check, service_updated.name}, state.config.ping_interval_ms)

    {:noreply, put_in(state.services[name], service_updated)}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ServiceHealth: ignoring unexpected info #{inspect(msg)}")
    {:noreply, state}
  end

  @spec healthy?(host_key :: String.t(), node :: node()) :: boolean()
  def healthy?(host_key, node \\ node()) do
    case :ets.lookup(@health_table, {node, host_key}) do
      [{{^node, ^host_key}, :ko}] -> false
      _ -> true
    end
  rescue
    # if the table doesnt exist we will asume healthy just in case.
    _ -> true
  end

  def statuses do
    GenServer.call(__MODULE__, :statuses)
  end

  def set_unhealthy(host_key) do
    GenServer.cast(__MODULE__, {:set_unhealthy, host_key})
  end

  defp down_domains(state) do
    for {_name, %{health: :ko, domains: domains}} <- state.services,
        domain <- domains do
      domain
    end
  end

  @doc false
  @spec check(map(), non_neg_integer()) :: :ok | :ko
  def check(service, timeout) do
    response =
      Finch.build(
        :get,
        service.target <> service.health_path,
        if(service.health_domain, do: [{"host", service.health_domain}], else: [])
      )
      |> Finch.request(ElixirGateway.HealthFinch, request_timeout: timeout)

    case response do
      {:ok, %Finch.Response{status: 200}} ->
        :ok

      {:ok, %Finch.Response{} = response} ->
        Logger.warning("Unhealthy service [#{service.name}]. Returned #{inspect(response)}")
        :ko

      {:error, err} ->
        Logger.warning("Unhealthy service [#{service.name}]. Error ocurred: #{inspect(err)}")
        :ko
    end
  end

  defp save_update(service, service_updated) do
    if service.health != service_updated.health do
      service.domains
      |> Enum.each(fn domain ->
        Logger.warning("Status of domain #{domain} changed to #{service_updated.health}")

        case service_updated.health do
          :ok -> :ets.delete(@health_table, {node(), domain})
          :ko -> :ets.insert(@health_table, {{node(), domain}, :ko})
        end
      end)

      GenServer.abcast(
        Node.list(),
        __MODULE__,
        {:peer_update, node(), service_updated.domains, service_updated.health}
      )

      :telemetry.execute([:elixirgateway, :service_health, :transition], %{count: 1}, %{
        service: service.name,
        to: to_string(service_updated.health)
      })
    end
  end

  @doc false
  @spec update_health(map(), :ok | :ko) :: map()
  def update_health(%{health: :ok} = service, :ok) do
    %{service | ko_counter: 0}
  end

  def update_health(%{health: :ko} = service, :ko) do
    %{service | ok_counter: 0}
  end

  def update_health(%{health: :ko, ok_counter: ok_counter} = service, :ok)
      when ok_counter < 2 do
    %{service | ok_counter: service.ok_counter + 1}
  end

  def update_health(%{health: :ok, ko_counter: ko_counter} = service, :ko)
      when ko_counter < 3 do
    %{service | ko_counter: service.ko_counter + 1}
  end

  def update_health(%{health: :ko, ok_counter: ok_counter} = service, :ok)
      when ok_counter >= 2 do
    %{service | ok_counter: 0, health: :ok}
  end

  def update_health(%{health: :ok, ko_counter: ko_counter} = service, :ko)
      when ko_counter >= 3 do
    %{service | ko_counter: 0, health: :ko}
  end
end
