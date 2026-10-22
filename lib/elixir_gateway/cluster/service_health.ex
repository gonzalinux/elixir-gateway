defmodule ElixirGateway.Cluster.ServiceHealth do
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
      :public,
      read_concurrency: true
    ])

    config = Application.get_env(:elixirgateway, :health, [])

    mixed_config = %{
      timeout_ms: Keyword.get(config, :timeout_ms, @default_timeout_ms),
      ping_interval_ms: Keyword.get(config, :ping_interval_ms, @default_ping_interval_ms)
    }

    services =
      ElixirGateway.ConfigLoader.get_services()
      |> Enum.map(fn {service, url} ->
        {service, %{url: url, health: :ok, fail: 0, success: 0}}
      end)
      |> Enum.into(%{})

    {:ok, %{config: mixed_config, services: services}}
  end
end
