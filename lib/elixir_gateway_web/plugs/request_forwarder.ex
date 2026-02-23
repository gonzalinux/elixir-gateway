defmodule ElixirGatewayWeb.Plugs.RequestForwarder do
  @moduledoc """
  Forwards HTTP requests to target services using Finch for high performance.
  """

  import Plug.Conn
  require Logger

  alias ElixirGateway.Cluster.Config

  def init(opts), do: opts

  def call(conn, opts) do
    # Check target_node assignment from LoadDistributionRouter
    target_node = conn.assigns[:target_node]

    case target_node do
      :local ->
        process_locally(conn, opts)

      {:remote, node} ->
        # Forward to remote node via RPC
        Logger.info("Forwarding request to remote node: #{node}")
        forward_to_remote_node(conn, node)

      nil ->
        # No target_node assigned, fall back to legacy behavior
        # This happens when LoadDistributionRouter is not in the pipeline
        case ElixirGateway.Cluster.ConnectionRegistry.get_node(conn) do
          :local ->
            process_locally(conn, opts)

          {:remote, node} ->
            Logger.info("Request affinity points to remote node: #{node}")
            forward_to_remote_node(conn, node)

          :new_session ->
            # New session without load distribution routing - process locally
            process_locally(conn, opts)

          :not_clustered ->
            process_locally(conn, opts)
        end
    end
  end

  defp process_locally(conn, _opts) do
    # Record request for load distribution tracking
    if Config.load_distribution_enabled?() do
      ElixirGateway.Cluster.LoadDistributor.record_request(node())
    end

    target_url = conn.assigns[:target_url]

    if target_url do
      forward_request(conn, target_url)
    else
      conn
    end
  end

  defp forward_to_remote_node(conn, node) do
    start_time = System.monotonic_time()

    # Serialize request data for RPC call
    request_data = %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string,
      headers: conn.req_headers,
      body: get_request_body(conn),
      target_url: conn.assigns[:target_url],
      original_host: conn.assigns[:original_host]
    }

    # Forward via RPC with 45s timeout (allows for 40s backend timeout)
    case :rpc.call(node, __MODULE__, :execute_forwarded_request, [request_data], 45_000) do
      {:ok, status, headers, body} ->
        # Record successful forwarded request
        if Config.load_distribution_enabled?() do
          ElixirGateway.Cluster.LoadDistributor.record_request(node)
        end

        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)
        emit_rpc_telemetry(node, :ok, duration)

        Logger.info(
          "Load distributor: RPC forwarding successful to #{node} - Status: #{status}, Duration: #{duration_ms}ms"
        )

        conn
        |> put_response_headers(headers)
        |> send_resp(status, body)
        |> halt()

      {:error, reason} ->
        duration = System.monotonic_time() - start_time
        emit_rpc_telemetry(node, :error, duration)

        Logger.error("RPC forwarding failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{error: "Service unavailable"}))
        |> halt()

      {:badrpc, :nodedown} ->
        # Remote node is down - fallback to local processing
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)
        emit_rpc_telemetry(node, :nodedown, duration)

        Logger.warning(
          "Load distributor: Remote node down (#{node}), falling back to local processing (attempt took #{duration_ms}ms)"
        )

        # Record local request since we're falling back
        if Config.load_distribution_enabled?() do
          ElixirGateway.Cluster.LoadDistributor.record_request(node())
        end

        process_locally(conn, [])

      {:badrpc, reason} ->
        duration = System.monotonic_time() - start_time
        emit_rpc_telemetry(node, :badrpc, duration)

        Logger.error("RPC call failed with badrpc: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "Service temporarily unavailable"}))
        |> halt()
    end
  end

  @doc """
  Executes a forwarded request on the remote node.

  This function is called via RPC from the primary node. It receives the
  serialized request data, makes the backend request using Finch, and
  returns the response.

  Returns:
  - `{:ok, status, headers, body}` on success
  - `{:error, reason}` on failure
  """
  def execute_forwarded_request(request_data) do
    Logger.info("Executing RPC forwarded request: #{request_data.method} #{request_data.path}")

    try do
      # Build target URL
      full_url =
        build_target_url(
          request_data.target_url,
          request_data.path,
          request_data.query
        )

      # Prepare headers (already filtered by the primary node)
      headers = request_data.headers

      # Build and execute Finch request
      finch_request =
        Finch.build(
          String.upcase(request_data.method),
          full_url,
          headers,
          request_data.body
        )

      case Finch.request(finch_request, ElixirGateway.Finch,
             receive_timeout: 40_000,
             request_timeout: 40_000
           ) do
        {:ok, response} ->
          Logger.info("RPC forwarded request succeeded: #{response.status}")
          {:ok, response.status, response.headers, response.body}

        {:error, reason} ->
          Logger.error("RPC forwarded request failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("RPC forwarded request error: #{inspect(error)}")
        {:error, error}
    end
  end

  defp forward_request(conn, target_url) do
    start_time = System.monotonic_time()

    try do
      # Build the target URL with path and query string
      full_url = build_target_url(target_url, conn.request_path, conn.query_string)

      Logger.info(
        "Forwarding #{conn.method} request to: #{full_url} (Originally #{conn.assigns.original_host}"
      )

      # Prepare headers (exclude hop-by-hop headers)
      headers = prepare_headers(conn)
      Logger.info("Request headers: #{inspect(headers)}")

      # Get request body - either from parsed params or raw body
      Logger.info("Getting request body...")
      body = get_request_body(conn)
      Logger.info("Body retrieved, length: #{byte_size(body)} bytes")

      # Build Finch request
      method = String.upcase(conn.method)
      finch_request = Finch.build(method, full_url, headers, body)
      Logger.info("Built Finch request, executing...")

      # Execute request with timeout for large file uploads
      case Finch.request(finch_request, ElixirGateway.Finch,
             receive_timeout: 40_000,
             request_timeout: 40_000
           ) do
        {:ok, response} ->
          duration = System.monotonic_time() - start_time
          log_request(conn, response.status, duration)

          conn
          |> put_response_headers(response.headers)
          |> send_resp(response.status, response.body)
          |> halt()

        {:error, reason} ->
          duration = System.monotonic_time() - start_time
          Logger.error("Request forwarding failed: #{inspect(reason)}")
          log_request(conn, 502, duration)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(502, Jason.encode!(%{error: "Service unavailable"}))
          |> halt()
      end
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        Logger.error("Request forwarding error: #{inspect(error)}")
        log_request(conn, 500, duration)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "Internal server error"}))
        |> halt()
    end
  end

  defp build_target_url(base_url, path, query_string) do
    url = base_url <> path

    if query_string != "" do
      url <> "?" <> query_string
    else
      url
    end
  end

  defp prepare_headers(conn) do
    # Filter out hop-by-hop headers and connection-specific headers
    excluded_headers =
      MapSet.new([
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length"
      ])

    conn.req_headers
    |> Enum.reject(fn {name, _value} ->
      MapSet.member?(excluded_headers, String.downcase(name))
    end)
    |> Enum.map(fn {name, value} -> {name, value} end)
  end

  defp put_response_headers(conn, headers) do
    # Filter response headers
    excluded_headers =
      MapSet.new([
        "connection",
        "keep-alive",
        "transfer-encoding",
        "content-length"
      ])

    Enum.reduce(headers, conn, fn {name, value}, acc_conn ->
      if not MapSet.member?(excluded_headers, String.downcase(name)) do
        put_resp_header(acc_conn, String.downcase(name), value)
      else
        acc_conn
      end
    end)
  end

  defp get_request_body(conn) do
    content_type = get_content_type(conn)

    cond do
      # If body has already been parsed as JSON, re-encode it
      String.starts_with?(content_type, "application/json") and conn.body_params != %{} ->
        Jason.encode!(conn.body_params)

      # If params were parsed from form data, encode as form
      String.starts_with?(content_type, "application/x-www-form-urlencoded") and
          conn.body_params != %{} ->
        URI.encode_query(conn.body_params)

      # For multipart data, check if it was parsed
      String.starts_with?(content_type, "multipart/") and conn.params != %{} ->
         read_raw_body(conn)
      # For all other content types (including binary), use raw body
      true ->
        read_raw_body(conn)
    end
  end

  defp get_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] -> String.downcase(content_type)
      [] -> ""
    end
  end

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn,
           length: 20_000_000,
           read_length: 1_000_000,
           read_timeout: 15_000
         ) do
      {:ok, body, conn} ->
        {body, conn}

      {:more, partial_body, conn} ->
        # For large binary files, read in chunks
        read_remaining_body(conn, partial_body)

      {:error, _reason} ->
        {"", conn}
    end
  end

  defp read_remaining_body(conn, acc_body) do
    case Plug.Conn.read_body(conn,
           length: 20_000_000,
           read_length: 1_000_000,
           read_timeout: 15_000
         ) do
      {:ok, body, conn} -> {acc_body <> body, conn}
      {:more, partial_body, conn} -> read_remaining_body(conn, acc_body <> partial_body)
      {:error, _reason} -> {acc_body, conn}
    end
  end

  defp log_request(conn, status, duration_native) do
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    Logger.info([
      "method=",
      conn.method,
      " path=",
      conn.request_path,
      " status=",
      to_string(status),
      " duration=",
      to_string(duration_ms),
      "ms",
      " target=",
      conn.assigns[:target_url] || "unknown"
    ])

    # Emit telemetry event
    emit_telemetry(conn, status, duration_native)
  end

  defp emit_telemetry(conn, status, duration_native) do
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    # Sample 1 in 10 requests for path tracking to reduce cardinality
    metadata =
      if rem(System.unique_integer([:positive]), 10) == 0 do
        %{
          method: String.upcase(conn.method),
          status: to_string(status),
          target_service: conn.assigns[:target_url] || "unknown",
          path: conn.request_path,
          host:
            conn.assigns[:original_host] || get_req_header(conn, "host") |> List.first() ||
              "unknown"
        }
      else
        %{
          method: String.upcase(conn.method),
          status: to_string(status),
          target_service: conn.assigns[:target_url] || "unknown",
          host:
            conn.assigns[:original_host] || get_req_header(conn, "host") |> List.first() ||
              "unknown"
        }
      end

    :telemetry.execute(
      [:elixirgateway, :request, :complete],
      %{duration: duration_ms},
      metadata
    )
  end

  defp emit_rpc_telemetry(destination_node, status, duration_native) do
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)

    :telemetry.execute(
      [:elixirgateway, :rpc, :forward],
      %{duration: duration_ms},
      %{
        destination_node: to_string(destination_node),
        status: to_string(status)
      }
    )
  end
end
