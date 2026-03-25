defmodule ElixirGatewayWeb.Plugs.HttpsRedirectPlug do
  @moduledoc """
  Redirects HTTP requests to HTTPS for services configured with force_https: true.

  Must run after DomainRouter, which sets conn.assigns[:force_https].
  Respects the x-forwarded-proto header for requests arriving via a proxy.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if https?(conn) or not conn.assigns[:force_https] do
      conn
    else
      redirect_to_https(conn)
    end
  end

  defp https?(conn) do
    conn.scheme == :https or
      get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  defp redirect_to_https(conn) do
    host = conn.assigns[:original_host] || conn.host
    path = conn.request_path
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"

    conn
    |> put_resp_header("location", "https://#{host}#{path}#{query}")
    |> send_resp(301, "")
    |> halt()
  end
end
