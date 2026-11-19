defmodule ElixirGatewayWeb.Plugs.DomainRouter do
  @moduledoc """
  Plug that determines the target service based on the incoming domain.
  """

  import Plug.Conn
  require Logger

  @default_timeout 30

  def init(opts), do: opts

  def call(conn, _opts) do
    host = get_host(conn)

    case resolve_service_entry(host) do
      nil ->
        Logger.warning("No service configured for host: #{host}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Service not found for host: #{host}"}))
        |> halt()

      {service_key, target_url} ->
        conn
        |> assign(:target_url, target_url)
        |> assign(:service_key, service_key)
        |> assign(:original_host, host)
        |> assign(:force_https, force_https?(host))
        |> assign(:timeout, resolve_timeout(host, conn.method, conn.request_path))
    end
  end

  @doc """
  Resolves a host to its target service URL using local configuration.

  Returns the target URL string, or nil if no service is configured for the host.
  Checks exact match, wildcard patterns, and the default_any fallback in order.
  """
  @spec resolve_service(String.t()) :: String.t() | nil
  def resolve_service(host) do
    case resolve_service_entry(host) do
      {_service_key, target_url} -> target_url
      nil -> nil
    end
  end

  @doc """
  Like `resolve_service/1`, but returns `{service_key, target_url}`, where `service_key`
  is the routing key that matched (e.g. `"api.example.com"`, `"*.example.com"` or
  `"default_any"`), or nil if no service is configured for the host.
  """
  @spec resolve_service_entry(String.t()) :: {String.t(), String.t()} | nil
  def resolve_service_entry(host) do
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}

    exact_entry(services, host) ||
      wildcard_entry(services, host) ||
      if(host != "default", do: exact_entry(services, "default_any"))
  end

  defp exact_entry(services, key) do
    case Map.fetch(services, key) do
      {:ok, target_url} -> {key, target_url}
      :error -> nil
    end
  end

  defp wildcard_entry(services, host) do
    Enum.find(services, fn
      {"*" <> suffix, _target_url} -> String.ends_with?(host, suffix) or host == suffix
      _ -> false
    end)
  end

  @doc """
  Maps a request host to a bounded label for Prometheus metrics.

  Only hosts registered in the gateway services produce their own label, so bots
  probing random hostnames cannot inflate metric cardinality:

    * exact match (or the apex of a wildcard entry) → the lowercased host
    * other wildcard match → the wildcard pattern, e.g. `"*example.com"`
    * anything else (including hosts only caught by `default_any`) → `"unregistered"`
  """
  def metrics_host(nil), do: "unregistered"

  def metrics_host(host) when is_binary(host) do
    host = host |> String.split(":") |> List.first() |> String.downcase()
    services = Application.get_env(:elixirgateway, :gateway)[:services] || %{}

    cond do
      host not in ["default", "default_any"] and Map.has_key?(services, host) ->
        host

      pattern = find_wildcard_pattern(services, host) ->
        if host == wildcard_suffix(pattern), do: host, else: pattern

      true ->
        "unregistered"
    end
  end

  defp find_wildcard_pattern(services, host) do
    Enum.find_value(services, fn
      {"*" <> suffix = pattern, _target} ->
        if String.ends_with?(host, suffix), do: pattern

      _ ->
        nil
    end)
  end

  defp wildcard_suffix("*" <> suffix), do: String.trim_leading(suffix, ".")

  defp force_https?(host) do
    force_https_map = Application.get_env(:elixirgateway, :gateway)[:force_https] || %{}

    Map.get(force_https_map, host) ||
      find_wildcard_match(force_https_map, host) ||
      false
  end

  defp resolve_timeout(host, method, path) do
    timeouts = Application.get_env(:elixirgateway, :gateway)[:timeouts] || %{}

    path_matchers =
      Map.get(timeouts, host) ||
        find_wildcard_match(timeouts, host) ||
        if(host != "default", do: Map.get(timeouts, "default_any"))

    case path_matchers do
      nil -> @default_timeout
      matchers -> find_timeout(matchers, method, path)
    end
  end

  defp find_timeout(matchers, method, path) do
    Enum.find_value(matchers, @default_timeout, fn %{
                                                     pattern: pattern,
                                                     method: m,
                                                     timeout: timeout
                                                   } ->
      if Regex.match?(pattern, path) and (m == ".*" or String.upcase(m) == String.upcase(method)) do
        timeout
      end
    end)
  end

  defp find_wildcard_match(services, host) do
    Enum.find_value(services, fn
      {"*" <> suffix, target_url} ->
        if String.ends_with?(host, suffix) or host == suffix, do: target_url

      _ ->
        nil
    end)
  end

  defp get_host(conn) do
    if conn.host do
      conn.host
    else
      case get_req_header(conn, "host") do
        [host | _] ->
          # Remove port if present
          host
          |> String.split(":")
          |> List.first()

        [] ->
          "default"
      end
    end
  end
end
