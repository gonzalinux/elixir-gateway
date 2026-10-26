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

    services
    |> Enum.each(fn {name, _service} ->
      Process.send_after(self(), {:check, name}, mixed_config.ping_interval_ms)
    end)

    {:ok, %{config: mixed_config, services: services}}
  end

  def healthy?(host_key) do
    try do
      case :ets.lookup(@health_table, host_key) do
        [{^host_key, :ko}] -> false
        _ -> true
      end
    rescue
      # if the table doesnt exist we will asume healthy just in case.
      _ -> true
    end
  end

  @impl true
  def handle_info({:check, name}, state) do
    service = state.services[name]

    response =
      Finch.build(
        :get,
        service.target <> service.health_path,
        if(service.health_domain, do: [{"host", service.health_domain}], else: [])
      )
      |> Finch.request(ElixirGateway.HealthFinch, request_timeout: state.config.timeout_ms)

    health =
      case response do
        {:ok, %Finch.Response{status: 200}} -> :ok
        _ -> :ko
      end

    service_updated = update_health(service, health)

    if service.health != service_updated.health do
      service.domains
      |> Enum.each(fn domain ->
        Logger.warning("Status of domain #{domain} changed to #{service_updated.health}")
        :ets.insert(@health_table, {domain, service_updated.health})
      end)
    end

    Process.send_after(self(), {:check, service_updated.name}, state.config.ping_interval_ms)

    {:noreply, %{state | services: %{state.services | service.name => service_updated}}}
  end

  defp update_health(%{health: :ok} = service, :ok) do
    %{service | ko_counter: 0}
  end

  defp update_health(%{health: :ko} = service, :ko) do
    %{service | ok_counter: 0}
  end

  defp update_health(%{health: :ko, ok_counter: ok_counter} = service, :ok)
       when ok_counter < 2 do
    %{service | ok_counter: service.ok_counter + 1}
  end

  defp update_health(%{health: :ok, ko_counter: ko_counter} = service, :ko)
       when ko_counter < 3 do
    %{service | ko_counter: service.ko_counter + 1}
  end

  defp update_health(%{health: :ko, ok_counter: ok_counter} = service, :ok)
       when ok_counter >= 2 do
    %{service | ok_counter: 0, health: :ok}
  end

  defp update_health(%{health: :ok, ko_counter: ko_counter} = service, :ko)
       when ko_counter >= 3 do
    %{service | ko_counter: 0, health: :ko}
  end
end
