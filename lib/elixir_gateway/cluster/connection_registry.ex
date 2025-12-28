defmodule ElixirGateway.Cluster.ConnectionRegistry do
  @moduledoc """
  Local connection registry for persistent sticky sessions with TTL.

  Maintains session affinity mapping: {client_ip, session_id} → backend_node

  This ensures that requests from the same client/session are always
  routed to the same backend node for consistency, which is critical when:
  - Backend databases have eventual consistency (need time to sync)
  - WebSocket connections must stay on the same backend node
  - Stateful sessions require consistent routing

  ## Architecture

  This implementation uses a **local ETS table** for session storage since the
  gateway runs in active-passive mode (only one instance handles traffic at a time).
  When DNS failover occurs, the new active gateway starts with an empty session
  registry, which is expected behavior—clients will reconnect and establish new
  sessions on the active instance.

  ### Storage Structure

  Sessions are stored in ETS as: `{session_key, backend_node, last_access_ms}`

  Where:
  - `session_key`: `{client_ip, session_id}` tuple
  - `backend_node`: Erlang node name of the backend server
  - `last_access_ms`: Timestamp of last request (System.system_time(:millisecond))

  ## How It Works

  ### First Request
  1. Extract client IP (X-Forwarded-For → X-Real-IP → remote_ip)
  2. Extract session ID (Sec-WebSocket-Key → cookie → X-Session-ID → nil)
  3. Check ETS for existing session
  4. If not found, register session for current backend node
  5. Route to backend

  ### Subsequent Requests
  1. Look up session in ETS
  2. Update `last_access_ms` to keep session alive
  3. Route to same backend node

  ### TTL Cleanup
  - Periodic cleanup task runs every N minutes (default: 5)
  - Removes sessions where `last_access_ms < (now - TTL)` (default: 30min)
  - Logs number of sessions cleaned up

  ## Session Identification

  Client IP Priority:
  1. `X-Forwarded-For` header (first IP in chain)
  2. `X-Real-IP` header
  3. `remote_ip` from connection

  Session ID Priority:
  1. `Sec-WebSocket-Key` header (WebSocket connections)
  2. `_elixirgateway_key` cookie (Phoenix sessions)
  3. `X-Session-ID` custom header
  4. `nil` (IP-only affinity)

  ## Features

  - **Persistent sessions**: Sessions survive beyond individual request lifecycles
  - **TTL-based cleanup**: Automatic removal of stale sessions after inactivity
  - **Active session tracking**: `last_access_ms` updated on every request
  - **Low overhead**: Simple ETS lookups, no distributed coordination
  - **Monitoring**: Exposes metrics for registry size via `session_count/0`
  - **Memory bounded**: TTL cleanup prevents unbounded growth

  ## Configuration

      config :elixirgateway, :cluster,
        enabled: true,
        session_ttl_minutes: 30,          # Session expires after 30min of inactivity
        cleanup_interval_minutes: 5       # Cleanup runs every 5min

  ## Monitoring

      # Get active session count
      ElixirGateway.Cluster.ConnectionRegistry.session_count()

      # Prometheus metric (via PromEx)
      elixirgateway_session_registry_active_sessions

  ## Database Consistency Use Case

  For backends with eventual consistency (e.g., distributed databases that take
  time to sync), sticky sessions ensure the same client always hits the same
  backend node, giving the database time to reach consistency without exposing
  inconsistent data to clients.

  Example: Client writes to node A, then immediately reads. Without sticky sessions,
  the read might go to node B, which hasn't received the write yet. With sticky
  sessions, both write and read go to node A, ensuring consistency.
  """

  use GenServer
  require Logger

  @session_table :elixirgateway_sticky_sessions
  @default_session_ttl_minutes 30
  @default_cleanup_interval_minutes 5

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Determines which backend node should handle a connection.

  Looks up existing session affinity or creates new affinity on first access.
  Updates last_access_time to keep session alive.

  Returns:
  - `:local` - This backend node should handle it
  - `{:remote, node}` - Forward to the specified backend node
  - `:not_clustered` - Clustering is disabled, handle locally
  """
  def get_node(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)

      case lookup_session(key) do
        {:ok, backend_node} ->
          # Update last access time to keep session alive
          touch_session(key, backend_node)

          if backend_node == node() do
            :local
          else
            {:remote, backend_node}
          end

        :not_found ->
          # First time seeing this connection, claim it for this backend node
          register_session(key, node())
          :local
      end
    else
      :not_clustered
    end
  end

  @doc """
  Registers a connection affinity for a specific backend node.

  Note: Usually not needed as get_node/1 auto-registers on first access.
  Kept for backward compatibility and explicit registration.
  """
  def register_connection(conn) when is_map(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)
      register_session(key, node())
    else
      :ok
    end
  end

  def register_connection(key) when is_tuple(key) do
    if clustering_enabled?() do
      register_session(key, node())
    else
      :ok
    end
  end

  @doc """
  Explicitly unregisters a connection affinity.

  Generally not needed since TTL-based cleanup handles removal.
  Useful for explicit session termination (e.g., user logout, connection close).
  """
  def unregister_connection(conn) when is_map(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)
      unregister_session(key)
    else
      :ok
    end
  end

  def unregister_connection(key) when is_tuple(key) do
    if clustering_enabled?() do
      unregister_session(key)
    else
      :ok
    end
  end

  @doc """
  Returns the current number of active sessions in the registry.
  Useful for monitoring and metrics.
  """
  def session_count do
    if clustering_enabled?() do
      case :ets.info(@session_table, :size) do
        :undefined -> 0
        size when is_integer(size) -> size
      end
    else
      0
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    if clustering_enabled?() do
      # Create ETS table for session storage
      # Table structure: {session_key, backend_node, last_access_ms}
      :ets.new(@session_table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

      # Schedule periodic cleanup
      config = get_config()
      cleanup_interval_ms = config.cleanup_interval_minutes * 60 * 1000
      schedule_cleanup(cleanup_interval_ms)

      Logger.info(
        "Connection registry initialized - Session TTL: #{config.session_ttl_minutes}min, " <>
          "Cleanup interval: #{config.cleanup_interval_minutes}min"
      )

      {:ok, %{config: config, cleanup_interval_ms: cleanup_interval_ms}}
    else
      Logger.debug("Connection registry disabled (clustering not enabled)")
      {:ok, %{}}
    end
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    if clustering_enabled?() do
      cleanup_stale_sessions()
    end

    # Schedule next cleanup
    if state[:cleanup_interval_ms] do
      schedule_cleanup(state.cleanup_interval_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp clustering_enabled? do
    config = Application.get_env(:elixirgateway, :cluster, [])
    Keyword.get(config, :enabled, false)
  end

  defp get_config do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])

    %{
      session_ttl_minutes:
        Keyword.get(cluster_config, :session_ttl_minutes, @default_session_ttl_minutes),
      cleanup_interval_minutes:
        Keyword.get(
          cluster_config,
          :cleanup_interval_minutes,
          @default_cleanup_interval_minutes
        )
    }
  end

  # Session management functions

  defp lookup_session(key) do
    case :ets.lookup(@session_table, key) do
      [{^key, backend_node, _last_access_ms}] ->
        {:ok, backend_node}

      [] ->
        :not_found
    end
  rescue
    ArgumentError ->
      # Table doesn't exist (clustering disabled after start)
      :not_found
  end

  defp register_session(key, backend_node) do
    now_ms = System.system_time(:millisecond)

    try do
      :ets.insert(@session_table, {key, backend_node, now_ms})
      Logger.debug("Registered session #{inspect(key)} → node #{backend_node}")
      :ok
    rescue
      ArgumentError ->
        Logger.warning("Failed to register session #{inspect(key)}: table not available")
        {:error, :table_not_available}
    end
  end

  defp touch_session(key, backend_node) do
    now_ms = System.system_time(:millisecond)

    try do
      :ets.insert(@session_table, {key, backend_node, now_ms})
      :ok
    rescue
      ArgumentError ->
        :error
    end
  end

  defp unregister_session(key) do
    try do
      :ets.delete(@session_table, key)
      Logger.debug("Unregistered session #{inspect(key)}")
      :ok
    rescue
      ArgumentError ->
        Logger.debug("Failed to unregister session #{inspect(key)}: table not available")
        {:error, :table_not_available}
    end
  end

  # Cleanup functions

  defp cleanup_stale_sessions do
    config = get_config()
    ttl_ms = config.session_ttl_minutes * 60 * 1000
    now_ms = System.system_time(:millisecond)
    cutoff_ms = now_ms - ttl_ms

    try do
      # Find all stale sessions
      stale_sessions =
        :ets.select(@session_table, [
          {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff_ms}], [:"$1"]}
        ])

      # Delete them
      deleted_count =
        Enum.reduce(stale_sessions, 0, fn key, acc ->
          :ets.delete(@session_table, key)
          acc + 1
        end)

      if deleted_count > 0 do
        Logger.info(
          "Cleaned up #{deleted_count} stale sessions (TTL: #{config.session_ttl_minutes}min)"
        )
      else
        Logger.debug("No stale sessions to clean up")
      end

      deleted_count
    rescue
      ArgumentError ->
        Logger.warning("Failed to cleanup sessions: table not available")
        0
    end
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup_sessions, interval_ms)
  end

  defp extract_connection_key(conn) do
    # Extract client identifier (IP + session if available)
    client_ip = get_client_ip(conn)
    session_id = get_session_id(conn)

    {client_ip, session_id}
  end

  defp get_client_ip(conn) do
    # Try to get real IP from X-Forwarded-For or X-Real-IP
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        # Take first IP from X-Forwarded-For chain
        String.split(ip, ",") |> List.first() |> String.trim()

      [] ->
        case Plug.Conn.get_req_header(conn, "x-real-ip") do
          [ip | _] ->
            ip

          [] ->
            # Fall back to remote IP
            conn.remote_ip
            |> :inet.ntoa()
            |> to_string()
        end
    end
  end

  defp get_session_id(conn) do
    # Try multiple methods to get a session identifier
    # 1. WebSocket session from Sec-WebSocket-Key
    # 2. Session cookie
    # 3. Custom session header
    # 4. Default to nil

    cond do
      # WebSocket session key
      ws_key = Plug.Conn.get_req_header(conn, "sec-websocket-key") |> List.first() ->
        ws_key

      # Session cookie (Phoenix default)
      session = conn.cookies["_elixirgateway_key"] ->
        session

      # Custom session header
      session = Plug.Conn.get_req_header(conn, "x-session-id") |> List.first() ->
        session

      # No session identifier
      true ->
        nil
    end
  end
end
