defmodule ElixirGatewayWeb.GunWebSocketHandler do
  @moduledoc """
  WebSocket handler that uses Gun to proxy WebSocket connections to target services.
  Implements WebSock behavior for compatibility with Phoenix WebSocket adapter.
  """

  require Logger
  @behaviour WebSock

  @impl WebSock
  def init(state) do
    target_url = state.target_url
    headers = state.headers
    
    Logger.info("Gun WebSocket handler initializing connection to: #{target_url}")
    
    case establish_gun_connection(target_url, headers) do
      {:ok, gun_pid, stream_ref} ->
        new_state = Map.merge(state, %{
          gun_pid: gun_pid,
          gun_stream_ref: stream_ref,
          upgrade_pending: true
        })
        
        # Set a timeout for the upgrade
        Process.send_after(self(), :upgrade_timeout, 10000)
        
        {:ok, new_state}
      
      {:error, reason} ->
        Logger.error("Failed to establish Gun connection: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    if state.upgrade_pending do
      Logger.warning("WebSocket upgrade still pending, queuing message")
      {:ok, state}
    else
      case state.gun_stream_ref do
        nil ->
          Logger.warning("No Gun WebSocket stream available")
          {:ok, state}
        
        stream_ref ->
          :gun.ws_send(state.gun_pid, stream_ref, {:text, text})
          {:ok, state}
      end
    end
  end

  @impl WebSock
  def handle_in({binary, [opcode: :binary]}, state) do
    if state.upgrade_pending do
      Logger.warning("WebSocket upgrade still pending, queuing binary message")
      {:ok, state}
    else
      case state.gun_stream_ref do
        nil ->
          Logger.warning("No Gun WebSocket stream available")
          {:ok, state}
        
        stream_ref ->
          :gun.ws_send(state.gun_pid, stream_ref, {:binary, binary})
          {:ok, state}
      end
    end
  end

  @impl WebSock
  def handle_in({payload, [opcode: :ping]}, state) do
    case state.gun_stream_ref do
      nil -> 
        {:reply, :ok, {:pong, payload}, state}
      stream_ref ->
        :gun.ws_send(state.gun_pid, stream_ref, {:ping, payload})
        {:ok, state}
    end
  end

  @impl WebSock
  def handle_in({_payload, [opcode: :pong]}, state) do
    # Handle pong frames from client
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:gun_upgrade, _gun_pid, stream_ref, [<<"websocket">>], _headers}, state) do
    Logger.info("Gun WebSocket upgrade successful")
    new_state = %{state | 
      gun_stream_ref: stream_ref, 
      upgrade_pending: false
    }
    {:ok, new_state}
  end

  @impl WebSock
  def handle_info({:gun_response, gun_pid, stream_ref, :nofin, status, headers}, state) do
    Logger.error("Gun WebSocket upgrade failed with status #{status}, headers: #{inspect(headers)}")
    
    # Try to read the response body to get more details about the error
    case :gun.await_body(gun_pid, stream_ref, 5000) do
      {:ok, body} ->
        Logger.error("Response body: #{body}")
      {:error, reason} ->
        Logger.error("Failed to read response body: #{inspect(reason)}")
    end
    
    {:stop, :normal, state}
  end

  @impl WebSock
  def handle_info({:gun_error, _gun_pid, _stream_ref, reason}, state) do
    Logger.error("Gun error during WebSocket connection: #{inspect(reason)}")
    {:stop, :normal, state}
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
    {:stop, :normal, state}
  end

  @impl WebSock
  def handle_info({:gun_down, _gun_pid, _protocol, reason, _killed_streams}, state) do
    Logger.error("Gun connection down: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  @impl WebSock
  def handle_info(:upgrade_timeout, state) do
    if state.upgrade_pending do
      Logger.error("Gun WebSocket upgrade timeout")
      {:stop, :normal, state}
    else
      {:ok, state}
    end
  end

  @impl WebSock
  def handle_info(msg, state) do
    Logger.debug("Gun WebSocket handler received unexpected message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("Gun WebSocket handler terminated: #{inspect(reason)}")
    
    if state[:gun_pid] do
      :gun.close(state.gun_pid)
    end
    
    :ok
  end

  # Private functions

  defp establish_gun_connection(target_url, headers) do
    # Parse the WebSocket URL
    uri = URI.parse(target_url)
    
    # Convert ws:// to http:// for Gun connection
    scheme = case uri.scheme do
      "ws" -> :http
      "wss" -> :https
      other -> String.to_atom(other)
    end
    
    port = uri.port || (if scheme == :https, do: 443, else: 80)
    
    # Gun connection options
    gun_opts = %{
      retry: 0,
      http_opts: %{keepalive: :infinity},
      protocols: [:http]
    }
    
    Logger.info("Establishing Gun connection to #{uri.host}:#{port}")
    
    case :gun.open(String.to_charlist(uri.host), port, gun_opts) do
      {:ok, gun_pid} ->
        case :gun.await_up(gun_pid, 10000) do
          {:ok, _protocol} ->
            # Prepare WebSocket upgrade path
            path_with_query = if uri.query do
              "#{uri.path}?#{uri.query}"
            else
              uri.path || "/"
            end
            
            # Prepare headers for Gun
            gun_headers = prepare_gun_headers(headers)
            
            Logger.info("Sending WebSocket upgrade request to #{path_with_query}")
            
            # Send WebSocket upgrade request
            stream_ref = :gun.ws_upgrade(gun_pid, path_with_query, gun_headers)
            
            {:ok, gun_pid, stream_ref}
          
          {:error, reason} ->
            Logger.error("Gun connection failed to come up: #{inspect(reason)}")
            :gun.close(gun_pid)
            {:error, reason}
        end
      
      {:error, reason} ->
        Logger.error("Failed to open Gun connection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp prepare_gun_headers(headers) do
    # Convert headers to the format expected by Gun (charlist keys and values)
    headers
    |> Enum.map(fn {key, value} -> 
      {String.to_charlist(key), String.to_charlist(value)} 
    end)
  end
end