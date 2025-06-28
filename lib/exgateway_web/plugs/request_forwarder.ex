defmodule ElixirGatewayWeb.Plugs.RequestForwarder do
  @moduledoc """
  Forwards HTTP requests to target services using Finch for high performance.
  """
  
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    target_url = conn.assigns[:target_url]
    
    if target_url do
      forward_request(conn, target_url)
    else
      conn
    end
  end

  defp forward_request(conn, target_url) do
    start_time = System.monotonic_time()
    
    try do
      # Build the target URL with path and query string
      full_url = build_target_url(target_url, conn.request_path, conn.query_string)
      Logger.info("Forwarding #{conn.method} request to: #{full_url} (Originally #{conn.assigns.original_host}")
      
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
      
      # Execute request with shorter timeout
      case Finch.request(finch_request, ElixirGateway.Finch, receive_timeout: 10_000, request_timeout: 10_000) do
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
    excluded_headers = MapSet.new([
      "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
      "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length"
    ])
    
    conn.req_headers
    |> Enum.reject(fn {name, _value} -> MapSet.member?(excluded_headers, String.downcase(name)) end)
    |> Enum.map(fn {name, value} -> {name, value} end)
  end

  defp put_response_headers(conn, headers) do
    # Filter response headers
    excluded_headers = MapSet.new([
      "connection", "keep-alive", "transfer-encoding", "content-length"
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
      String.starts_with?(content_type, "application/x-www-form-urlencoded") and conn.params != %{} ->
        URI.encode_query(conn.params)
      
      # For all other content types (including binary), use raw body
      true ->
        case read_raw_body(conn) do
          {body, _conn} -> body
          _ -> ""
        end
    end
  end
  
  defp get_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] -> String.downcase(content_type)
      [] -> ""
    end
  end
  
  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn, read_length: 1_000_000, read_timeout: 5_000) do
      {:ok, body, conn} -> {body, conn}
      {:more, _chunk, _conn} -> {"", conn}  # Body already consumed
      {:error, _reason} -> {"", conn}
    end
  end

  defp log_request(conn, status, duration_native) do
    duration_ms = System.convert_time_unit(duration_native, :native, :millisecond)
    
    Logger.info([
      "method=", conn.method,
      " path=", conn.request_path,
      " status=", to_string(status),
      " duration=", to_string(duration_ms), "ms",
      " target=", conn.assigns[:target_url] || "unknown"
    ])
  end
end