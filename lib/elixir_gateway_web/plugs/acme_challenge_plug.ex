defmodule ElixirGatewayWeb.Plugs.AcmeChallengePlug do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.path_info do
      [token] when byte_size(token) > 0 -> serve_token(conn, token)
      _ -> conn |> send_resp(404, "")
    end
    |> halt()
  end

  defp serve_token(conn, token) do
    webroot = cert_store_config(:acme_webroot)
    path = Path.join([webroot, ".well-known", "acme-challenge", token])

    case File.read(path) do
      {:ok, contents} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, contents)

      {:error, _} ->
        conn |> send_resp(404, "")
    end
  end

  defp cert_store_config(key) do
    Application.get_env(:elixirgateway, :cert_store, [])
    |> Keyword.get(key)
  end
end
