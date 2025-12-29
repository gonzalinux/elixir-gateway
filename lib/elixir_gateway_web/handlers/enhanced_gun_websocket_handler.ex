defmodule ElixirGatewayWeb.EnhancedGunWebSocketHandler do
  @moduledoc """
  Enhanced WebSocket handler with connection pooling, automatic reconnection,
  message queuing, and improved error handling.
  """

  require Logger
  @behaviour WebSock

  alias ElixirGatewayWeb.WebSocketConnectionPool
  alias ElixirGateway.Utils

  # Default configuration
  @default_config %{
    upgrade_timeout: 30_000,
    reconnect_max_attempts: 3,
    reconnect_base_delay: 1_000,
    reconnect_max_delay: 10_000,
    message_queue_max_size: 100,
    connection_timeout: 10_000
  }

  @impl WebSock
  def init(state) do
    target_url = state.target_url
    headers = state.headers
    config = get_websocket_config()

    Logger.info("Enhanced WebSocket handler initializing connection to: #{target_url}")

    initial_state =
      Map.merge(state, %{
        config: config,
        reconnect_attempts: 0,
        message_queue: :queue.new(),
        queue_size: 0,
        connection_status: :connecting,
        last_ping_at: System.system_time(:millisecond),
        ping_interval: 30_000
      })

    case establish_connection(target_url, headers, config) do
      {:ok, gun_pid, stream_ref} ->
        new_state =
          Map.merge(initial_state, %{
            gun_pid: gun_pid,
            gun_stream_ref: stream_ref,
            upgrade_pending: true,
            connection_status: :upgrading
          })

        # Set configurable upgrade timeout
        Process.send_after(self(), :upgrade_timeout, config.upgrade_timeout)

        # Schedule periodic ping
        schedule_ping(config)

        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to establish connection: #{inspect(reason)}")

        # Attempt reconnection if configured
        if config.reconnect_max_attempts > 0 do
          schedule_reconnect(initial_state)
          {:ok, initial_state}
        else
          {:stop, :normal, initial_state}
        end
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    handle_outgoing_message({:text, text}, state)
  end

  @impl WebSock
  def handle_in({binary, [opcode: :binary]}, state) do
    handle_outgoing_message({:binary, binary}, state)
  end

  @impl WebSock
  def handle_in({payload, [opcode: :ping]}, state) do
    case state.connection_status do
      :connected ->
        case state.gun_stream_ref do
          nil ->
            {:reply, :ok, {:pong, payload}, state}

          stream_ref ->
            :gun.ws_send(state.gun_pid, stream_ref, {:ping, payload})
            {:ok, state}
        end

      _ ->
        # Connection not ready, respond with pong locally
        {:reply, :ok, {:pong, payload}, state}
    end
  end

  @impl WebSock
  def handle_in({_payload, [opcode: :pong]}, state) do
    # Update last ping time
    new_state = %{state | last_ping_at: System.system_time(:millisecond)}
    {:ok, new_state}
  end

  @impl WebSock
  def handle_info({:gun_upgrade, _gun_pid, stream_ref, [<<"websocket">>], _headers}, state) do
    Logger.info("WebSocket upgrade successful")

    new_state = %{
      state
      | gun_stream_ref: stream_ref,
        upgrade_pending: false,
        connection_status: :connected,
        reconnect_attempts: 0
    }

    # Process any queued messages
    new_state = process_message_queue(new_state)

    {:ok, new_state}
  end

  @impl WebSock
  def handle_info({:gun_response, gun_pid, stream_ref, :fin, status, _headers}, state) do
    Logger.error("WebSocket upgrade failed with status #{status}")

    # Try to read response body for more details
    case :gun.await_body(gun_pid, stream_ref, 5000) do
      {:ok, body} ->
        Logger.error("Response body: #{body}")

      {:error, reason} ->
        Logger.error("Failed to read response body: #{inspect(reason)}")
    end

    # Return connection to pool and attempt reconnection
    WebSocketConnectionPool.remove_connection(state.target_url, gun_pid)

    if should_reconnect?(state) do
      schedule_reconnect(state)
      new_state = %{state | connection_status: :reconnecting, gun_pid: nil, gun_stream_ref: nil}
      {:ok, new_state}
    else
      {:stop, {:close, 1002, "Upgrade failed"}, state}
    end
  end

  @impl WebSock
  def handle_info({:gun_error, gun_pid, _stream_ref, reason}, state) do
    Logger.error("Gun error: #{inspect(reason)}")

    # Return connection to pool and attempt reconnection
    WebSocketConnectionPool.remove_connection(state.target_url, gun_pid)

    if should_reconnect?(state) do
      schedule_reconnect(state)
      new_state = %{state | connection_status: :reconnecting, gun_pid: nil, gun_stream_ref: nil}
      {:ok, new_state}
    else
      {:stop, {:close, 1002, "Connection error"}, state}
    end
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, {:text, data}}, state) do
    {:reply, :ok, {:text, data}, state}
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, {:binary, data}}, state) do
    {:reply, :ok, {:binary, data}, state}
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, {:ping, payload}}, state) do
    {:reply, :ok, {:ping, payload}, state}
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, {:pong, payload}}, state) do
    {:reply, :ok, {:pong, payload}, state}
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, :close}, state) do
    Logger.info("Target WebSocket closed connection")
    {:stop, {:close, 1000, "Target closed"}, state}
  end

  @impl WebSock
  def handle_info({:gun_ws, _gun_pid, _stream_ref, {:close, code, reason}}, state) do
    Logger.info("Target WebSocket closed with code #{code}: #{reason}")
    {:stop, {:close, code, reason}, state}
  end

  @impl WebSock
  def handle_info({:gun_down, gun_pid, _protocol, reason, _killed_streams}, state) do
    Logger.error("Gun connection down: #{inspect(reason)}")

    # Remove connection from pool
    WebSocketConnectionPool.remove_connection(state.target_url, gun_pid)

    if should_reconnect?(state) do
      schedule_reconnect(state)
      new_state = %{state | connection_status: :reconnecting, gun_pid: nil, gun_stream_ref: nil}
      {:ok, new_state}
    else
      {:stop, {:close, 1006, "Connection lost"}, state}
    end
  end

  @impl WebSock
  def handle_info(:upgrade_timeout, state) do
    if state.upgrade_pending do
      Logger.error("WebSocket upgrade timeout")

      if state.gun_pid do
        WebSocketConnectionPool.remove_connection(state.target_url, state.gun_pid)
      end

      if should_reconnect?(state) do
        schedule_reconnect(state)
        new_state = %{state | connection_status: :reconnecting, gun_pid: nil, gun_stream_ref: nil}
        {:ok, new_state}
      else
        {:stop, {:close, 1002, "Upgrade timeout"}, state}
      end
    else
      {:ok, state}
    end
  end

  @impl WebSock
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to #{state.target_url}")

    case establish_connection(state.target_url, state.headers, state.config) do
      {:ok, gun_pid, stream_ref} ->
        new_state = %{
          state
          | gun_pid: gun_pid,
            gun_stream_ref: stream_ref,
            upgrade_pending: true,
            connection_status: :upgrading
        }

        # Set upgrade timeout
        Process.send_after(self(), :upgrade_timeout, state.config.upgrade_timeout)

        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Reconnection failed: #{inspect(reason)}")

        if should_reconnect?(state) do
          schedule_reconnect(state)
          {:ok, state}
        else
          {:stop, {:close, 1006, "Reconnection failed"}, state}
        end
    end
  end

  @impl WebSock
  def handle_info(:send_ping, state) do
    case state.connection_status do
      :connected when not is_nil(state.gun_stream_ref) ->
        :gun.ws_send(state.gun_pid, state.gun_stream_ref, {:ping, ""})
        schedule_ping(state.config)
        {:ok, state}

      _ ->
        # Not connected, still schedule next ping
        schedule_ping(state.config)
        {:ok, state}
    end
  end

  @impl WebSock
  def handle_info(msg, state) do
    Logger.debug("Enhanced WebSocket handler received unexpected message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("Enhanced WebSocket handler terminated: #{inspect(reason)}")

    # Return connection to pool if it exists
    if state[:gun_pid] do
      WebSocketConnectionPool.return_connection(state.target_url, state.gun_pid)
    end

    :ok
  end

  # Private functions

  defp establish_connection(target_url, headers, _config) do
    case WebSocketConnectionPool.get_connection(target_url) do
      {:ok, gun_pid} ->
        # Use pooled connection
        {:ok, stream_ref} = send_websocket_upgrade(gun_pid, target_url, headers)
        {:ok, gun_pid, stream_ref}

      {:error, :pool_limit_reached} ->
        Logger.warning("Connection pool limit reached for #{target_url}")
        {:error, :pool_limit_reached}

      {:error, reason} ->
        Logger.error("Failed to get connection from pool: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_websocket_upgrade(gun_pid, target_url, headers) do
    uri = URI.parse(target_url)

    path_with_query =
      if uri.query do
        "#{uri.path}?#{uri.query}"
      else
        uri.path || "/"
      end

    gun_headers = prepare_gun_headers(headers)

    Logger.info("Sending WebSocket upgrade request to #{path_with_query}")

    stream_ref = :gun.ws_upgrade(gun_pid, path_with_query, gun_headers)
    {:ok, stream_ref}
  end

  defp handle_outgoing_message(message, state) do
    case state.connection_status do
      :connected when not is_nil(state.gun_stream_ref) ->
        # Connection is ready, send immediately
        :gun.ws_send(state.gun_pid, state.gun_stream_ref, message)
        {:ok, state}

      _ ->
        # Connection not ready, queue the message
        if state.queue_size < state.config.message_queue_max_size do
          new_queue = :queue.in(message, state.message_queue)
          new_state = %{state | message_queue: new_queue, queue_size: state.queue_size + 1}
          Logger.debug("Queued message, queue size: #{new_state.queue_size}")
          {:ok, new_state}
        else
          Logger.warning("Message queue full, dropping message")
          {:ok, state}
        end
    end
  end

  defp process_message_queue(state) do
    case :queue.out(state.message_queue) do
      {{:value, message}, new_queue} ->
        # Send the message
        case state.gun_stream_ref do
          nil ->
            Logger.warning("No stream available for queued message")
            state

          stream_ref ->
            :gun.ws_send(state.gun_pid, stream_ref, message)
            new_state = %{state | message_queue: new_queue, queue_size: state.queue_size - 1}
            # Process remaining messages
            process_message_queue(new_state)
        end

      {:empty, _} ->
        # No more messages to process
        Logger.info("Processed all queued messages")
        state
    end
  end

  defp should_reconnect?(state) do
    state.reconnect_attempts < state.config.reconnect_max_attempts
  end

  defp schedule_reconnect(state) do
    new_attempts = state.reconnect_attempts + 1

    # Exponential backoff with fixed jitter and max delay
    final_delay =
      Utils.exponential_backoff(
        new_attempts - 1,
        base_delay: state.config.reconnect_base_delay,
        max_delay: state.config.reconnect_max_delay,
        jitter: :fixed
      )

    Logger.info("Scheduling reconnection attempt #{new_attempts} in #{final_delay}ms")

    Process.send_after(self(), :reconnect, final_delay)

    # Update state with new attempt count
    %{state | reconnect_attempts: new_attempts}
  end

  defp schedule_ping(config) do
    Process.send_after(self(), :send_ping, config[:ping_interval] || 30_000)
  end

  defp prepare_gun_headers(headers) do
    headers
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp get_websocket_config do
    config = Application.get_env(:elixirgateway, :websocket, [])

    Map.merge(@default_config, %{
      upgrade_timeout: Keyword.get(config, :upgrade_timeout, @default_config.upgrade_timeout),
      reconnect_max_attempts:
        Keyword.get(config, :reconnect_max_attempts, @default_config.reconnect_max_attempts),
      reconnect_base_delay:
        Keyword.get(config, :reconnect_base_delay, @default_config.reconnect_base_delay),
      reconnect_max_delay:
        Keyword.get(config, :reconnect_max_delay, @default_config.reconnect_max_delay),
      message_queue_max_size:
        Keyword.get(config, :message_queue_max_size, @default_config.message_queue_max_size),
      connection_timeout:
        Keyword.get(config, :connection_timeout, @default_config.connection_timeout),
      ping_interval: Keyword.get(config, :ping_interval, 30_000)
    })
  end
end
