defmodule ElixirGatewayWeb.WebSocketConnectionPool do
  @moduledoc """
  Connection pool manager for WebSocket Gun connections.
  Manages a pool of reusable Gun connections per target host to improve performance
  and reduce connection overhead.
  """

  use GenServer
  require Logger

  @table_name :websocket_connection_pool
  @cleanup_interval 60_000

  defstruct [
    :target_host,
    :gun_pid,
    :created_at,
    :last_used_at,
    :in_use,
    :scheme
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get or create a Gun connection for the given target URL.
  Returns {:ok, gun_pid} or {:error, reason}.
  """
  def get_connection(target_url) do
    GenServer.call(__MODULE__, {:get_connection, target_url}, 10_000)
  end

  @doc """
  Return a connection to the pool when done using it.
  """
  def return_connection(target_url, gun_pid) do
    GenServer.cast(__MODULE__, {:return_connection, target_url, gun_pid})
  end

  @doc """
  Remove a connection from the pool (when it's no longer usable).
  """
  def remove_connection(target_url, gun_pid) do
    GenServer.cast(__MODULE__, {:remove_connection, target_url, gun_pid})
  end

  @doc """
  Get pool statistics for monitoring.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl GenServer
  def init(_opts) do
    # Create ETS table to store connections
    :ets.new(@table_name, [:set, :public, :named_table, {:keypos, 2}])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:get_connection, target_url}, _from, state) do
    case find_available_connection(target_url) do
      {:ok, gun_pid} ->
        mark_connection_in_use(target_url, gun_pid)
        {:reply, {:ok, gun_pid}, state}

      :not_found ->
        case create_new_connection(target_url) do
          {:ok, gun_pid} ->
            {:reply, {:ok, gun_pid}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    stats = get_pool_stats()
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:return_connection, target_url, gun_pid}, state) do
    mark_connection_available(target_url, gun_pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:remove_connection, target_url, gun_pid}, state) do
    remove_connection_from_pool(target_url, gun_pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_idle_connections()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:gun_down, gun_pid, _protocol, _reason, _killed_streams}, state) do
    # Remove the connection from pool when Gun reports it's down
    remove_connection_by_pid(gun_pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp find_available_connection(target_url) do
    target_host = extract_host_from_url(target_url)

    case :ets.match(
           @table_name,
           {%__MODULE__{
              target_host: target_host,
              in_use: false,
              gun_pid: :"$1",
              created_at: :_,
              last_used_at: :_,
              scheme: :_
            }, :"$1"}
         ) do
      [[gun_pid] | _] ->
        # Check if connection is still alive
        case :gun.info(gun_pid) do
          %{owner: _owner, socket: _socket, transport: _transport} ->
            {:ok, gun_pid}

          _ ->
            # Connection is dead, remove it
            remove_connection_from_pool(target_url, gun_pid)
            :not_found
        end

      [] ->
        :not_found
    end
  end

  defp create_new_connection(target_url) do
    target_host = extract_host_from_url(target_url)

    # Check if we've reached the pool limit for this host
    pool_config = Application.get_env(:elixir_gateway, :websocket)[:connection_pool]
    max_size = Keyword.get(pool_config, :size, 10)

    current_count = count_connections_for_host(target_host)

    if current_count >= max_size do
      Logger.warning("Connection pool limit reached for host: #{target_host}")
      {:error, :pool_limit_reached}
    else
      case establish_gun_connection(target_url) do
        {:ok, gun_pid} ->
          # Monitor the Gun process
          Process.monitor(gun_pid)

          # Store in pool
          connection = %__MODULE__{
            target_host: target_host,
            gun_pid: gun_pid,
            created_at: System.system_time(:millisecond),
            last_used_at: System.system_time(:millisecond),
            in_use: true,
            scheme: extract_scheme_from_url(target_url)
          }

          :ets.insert(@table_name, {connection, target_host})

          Logger.info(
            "Created new Gun connection for #{target_host}, pool size: #{current_count + 1}"
          )

          {:ok, gun_pid}

        {:error, reason} ->
          Logger.error("Failed to create Gun connection for #{target_host}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp establish_gun_connection(target_url) do
    uri = URI.parse(target_url)

    scheme =
      case uri.scheme do
        "ws" -> :http
        "wss" -> :https
        other -> String.to_atom(other)
      end

    port = uri.port || if scheme == :https, do: 443, else: 80

    gun_opts = %{
      retry: 0,
      http_opts: %{keepalive: :infinity},
      protocols: [:http]
    }

    case :gun.open(String.to_charlist(uri.host), port, gun_opts) do
      {:ok, gun_pid} ->
        case :gun.await_up(gun_pid, 10_000) do
          {:ok, _protocol} ->
            {:ok, gun_pid}

          {:error, reason} ->
            :gun.close(gun_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_connection_in_use(target_url, gun_pid) do
    target_host = extract_host_from_url(target_url)

    case :ets.match(
           @table_name,
           {%__MODULE__{
              target_host: target_host,
              gun_pid: gun_pid,
              created_at: :_,
              last_used_at: :_,
              in_use: :_,
              scheme: :_
            }, :"$_"}
         ) do
      [[connection] | _] ->
        updated_connection = %{
          connection
          | in_use: true,
            last_used_at: System.system_time(:millisecond)
        }

        :ets.insert(@table_name, {updated_connection, target_host})

      [] ->
        Logger.warning("Attempted to mark non-existent connection as in use: #{target_host}")
    end
  end

  defp mark_connection_available(target_url, gun_pid) do
    target_host = extract_host_from_url(target_url)

    case :ets.match(
           @table_name,
           {%__MODULE__{
              target_host: target_host,
              gun_pid: gun_pid,
              created_at: :_,
              last_used_at: :_,
              in_use: :_,
              scheme: :_
            }, :"$_"}
         ) do
      [[connection] | _] ->
        updated_connection = %{
          connection
          | in_use: false,
            last_used_at: System.system_time(:millisecond)
        }

        :ets.insert(@table_name, {updated_connection, target_host})

      [] ->
        Logger.warning("Attempted to mark non-existent connection as available: #{target_host}")
    end
  end

  defp remove_connection_from_pool(target_url, gun_pid) do
    target_host = extract_host_from_url(target_url)

    case :ets.match(
           @table_name,
           {%__MODULE__{
              target_host: target_host,
              gun_pid: gun_pid,
              created_at: :_,
              last_used_at: :_,
              in_use: :_,
              scheme: :_
            }, :"$_"}
         ) do
      [[connection] | _] ->
        :ets.delete_object(@table_name, {connection, target_host})
        :gun.close(gun_pid)
        Logger.info("Removed connection from pool: #{target_host}")

      [] ->
        Logger.debug("Attempted to remove non-existent connection: #{target_host}")
    end
  end

  defp remove_connection_by_pid(gun_pid) do
    case :ets.match(
           @table_name,
           {%__MODULE__{
              gun_pid: gun_pid,
              target_host: :"$1",
              created_at: :_,
              last_used_at: :_,
              in_use: :_,
              scheme: :_
            }, :"$1"}
         ) do
      [[target_host] | _] ->
        # Find the actual connection record to remove
        case :ets.match(
               @table_name,
               {%__MODULE__{
                  gun_pid: gun_pid,
                  target_host: target_host,
                  created_at: :_,
                  last_used_at: :_,
                  in_use: :_,
                  scheme: :_
                }, :"$_"}
             ) do
          [[connection] | _] ->
            :ets.delete_object(@table_name, {connection, target_host})
            Logger.info("Removed dead connection from pool: #{target_host}")

          [] ->
            Logger.debug("Connection already removed from pool")
        end

      [] ->
        Logger.debug("Attempted to remove non-existent connection by PID")
    end
  end

  defp count_connections_for_host(target_host) do
    match_spec = [
      {{%__MODULE__{
          target_host: target_host,
          gun_pid: :_,
          created_at: :_,
          last_used_at: :_,
          in_use: :_,
          scheme: :_
        }, :_}, [], [true]}
    ]

    :ets.select_count(@table_name, match_spec)
  end

  defp cleanup_idle_connections do
    pool_config = Application.get_env(:elixir_gateway, :websocket)[:connection_pool]
    max_idle_time = Keyword.get(pool_config, :max_idle_time, 300_000)
    current_time = System.system_time(:millisecond)
    cutoff_time = current_time - max_idle_time

    idle_connections =
      :ets.select(@table_name, [
        {{%__MODULE__{
            in_use: false,
            last_used_at: :"$1",
            target_host: :_,
            gun_pid: :_,
            created_at: :_,
            scheme: :_
          }, :"$_"}, [{:<, :"$1", cutoff_time}], [:"$_"]}
      ])

    Enum.each(idle_connections, fn {connection, _target_host} ->
      Logger.info("Cleaning up idle connection: #{connection.target_host}")
      :ets.delete_object(@table_name, {connection, connection.target_host})
      :gun.close(connection.gun_pid)
    end)

    if length(idle_connections) > 0 do
      Logger.info("Cleaned up #{length(idle_connections)} idle WebSocket connections")
    end
  end

  defp get_pool_stats do
    all_connections = :ets.tab2list(@table_name)

    stats =
      Enum.reduce(all_connections, %{}, fn {connection, _target_host}, acc ->
        host = connection.target_host
        host_stats = Map.get(acc, host, %{total: 0, in_use: 0, available: 0})

        updated_stats = %{
          total: host_stats.total + 1,
          in_use: if(connection.in_use, do: host_stats.in_use + 1, else: host_stats.in_use),
          available:
            if(connection.in_use, do: host_stats.available, else: host_stats.available + 1)
        }

        Map.put(acc, host, updated_stats)
      end)

    total_stats = %{
      total_connections: length(all_connections),
      total_hosts: map_size(stats),
      hosts: stats
    }

    total_stats
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp extract_host_from_url(url) do
    uri = URI.parse(url)
    port = uri.port || if uri.scheme in ["wss", "https"], do: 443, else: 80
    "#{uri.host}:#{port}"
  end

  defp extract_scheme_from_url(url) do
    case URI.parse(url).scheme do
      "ws" -> :http
      "wss" -> :https
      other -> String.to_atom(other)
    end
  end
end
