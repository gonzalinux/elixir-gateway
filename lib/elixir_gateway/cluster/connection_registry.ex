defmodule ElixirGateway.Cluster.ConnectionRegistry do
  @moduledoc """
  Distributed connection registry for sticky sessions.

  Uses Syn to maintain a distributed registry mapping:
  {client_ip, session_id} → node

  This ensures that requests from the same client/session are always
  routed to the same node for consistency (e.g., WebSocket connections,
  stateful sessions).
  """

  use GenServer
  require Logger

  @registry_scope :elixirgateway_connections

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Determines which node should handle a connection.

  Returns:
  - `:local` - This node should handle it
  - `{:remote, node}` - Forward to the specified node
  - `:not_clustered` - Clustering is disabled, handle locally
  """
  def get_node(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)

      case :syn.lookup(@registry_scope, key) do
        {_pid, node} ->
          if node == node() do
            :local
          else
            {:remote, node}
          end

        :undefined ->
          # First time seeing this connection, claim it for this node
          register_connection(key)
          :local
      end
    else
      :not_clustered
    end
  end

  @doc """
  Registers a connection affinity for the current node.
  """
  def register_connection(conn) when is_map(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)
      register_connection(key)
    else
      :ok
    end
  end

  def register_connection(key) when is_tuple(key) do
    if clustering_enabled?() do
      case :syn.register(@registry_scope, key, self(), node()) do
        :ok ->
          Logger.debug("Registered connection #{inspect(key)} on node #{node()}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register connection #{inspect(key)}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Unregisters a connection affinity.
  """
  def unregister_connection(conn) do
    if clustering_enabled?() do
      key = extract_connection_key(conn)

      case :syn.unregister(@registry_scope, key) do
        :ok ->
          Logger.debug("Unregistered connection #{inspect(key)}")
          :ok

        {:error, reason} ->
          Logger.debug("Failed to unregister connection #{inspect(key)}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    if clustering_enabled?() do
      # Initialize Syn if not already started
      ensure_syn_started()

      # Add registry scope
      :syn.add_node_to_scopes([@registry_scope])

      Logger.info("Connection registry initialized with scope: #{@registry_scope}")
    else
      Logger.debug("Connection registry disabled (clustering not enabled)")
    end

    {:ok, %{}}
  end

  ## Private Functions

  defp clustering_enabled? do
    config = Application.get_env(:elixirgateway, :cluster, [])
    Keyword.get(config, :enabled, false)
  end

  defp ensure_syn_started do
    case Application.ensure_all_started(:syn) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start Syn: #{inspect(reason)}"
    end
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
