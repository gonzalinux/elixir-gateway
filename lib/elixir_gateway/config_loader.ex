defmodule ElixirGateway.ConfigLoader do
  @moduledoc """
  Loads gateway configuration from a YAML file and populates Application env.

  Reads from the path in GATEWAY_CONFIG_FILE env var, falling back to
  priv/gateway.yaml. If neither exists, logs an error and leaves whatever
  :gateway config is already in place (the config/*.exs compile-time
  defaults, e.g. config/test.exs in the test env) unchanged — this is what
  lets `mix test` boot without a real gateway.yaml on disk. In production a
  missing file is a real misconfiguration, so it's logged at :error so it
  surfaces in the JSON log pipeline, even though the process doesn't crash.

  Supports ${VAR_NAME} substitution in any string value. Startup fails
  with a clear error if a referenced env var is not set.
  """

  require Logger

  @default_path "priv/gateway.yaml"

  def load do
    path = System.get_env("GATEWAY_CONFIG_FILE", @default_path)

    if File.exists?(path) do
      Logger.info("ConfigLoader: loading config from #{path}")

      path
      |> YamlElixir.read_from_file!()
      |> substitute_env_vars()
      |> apply_config()
    else
      Logger.error(
        "ConfigLoader: no config file found at #{path}, keeping existing gateway config"
      )
    end
  end

  # Goes over all the values recursively and replaces env variables.
  defp substitute_env_vars(value) when is_binary(value) do
    Regex.replace(~r/\$\{([A-Z0-9_]+)\}/, value, fn _, var_name ->
      System.get_env(var_name) ||
        raise "ConfigLoader: ${#{var_name}} referenced in gateway.yaml but env var is not set"
    end)
  end

  defp substitute_env_vars(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, substitute_env_vars(v)} end)
  end

  defp substitute_env_vars(value) when is_list(value) do
    Enum.map(value, &substitute_env_vars/1)
  end

  defp substitute_env_vars(value), do: value

  # --- Config application ---

  defp apply_config(config) do
    services = Map.get(config, "services", %{})
    default_timeout = Map.get(config, "timeout", 30)

    apply_services(services)
    apply_ssl_domains(services)
    apply_ddns(services)
    apply_timeouts(services, default_timeout)
  end

  defp apply_services(services) do
    routing_map =
      services
      |> Enum.flat_map(fn {_name, service} ->
        target = Map.fetch!(service, "target")

        service
        |> Map.get("domains", [])
        |> Enum.map(fn entry ->
          {name, _dns_challenge} = normalize_domain(entry)

          case name do
            "default" -> {"default_any", target}
            _ -> {name, target}
          end
        end)
      end)
      |> Map.new()

    existing = Application.get_env(:elixirgateway, :gateway, [])
    Application.put_env(:elixirgateway, :gateway, Keyword.put(existing, :services, routing_map))

    Logger.debug("ConfigLoader: loaded #{map_size(routing_map)} service routes")
  end

  defp apply_ssl_domains(services) do
    {http_domains, dns_domains, force_https_map} =
      Enum.reduce(services, {[], [], %{}}, fn {_name, service}, {http_acc, dns_acc, https_acc} ->
        normalized = service |> Map.get("domains", []) |> Enum.map(&normalize_domain/1)

        {new_http, new_dns} =
          if ssl_enabled?(service) do
            eligible =
              Enum.reject(normalized, fn {name, _} ->
                String.starts_with?(name, "*") or name == "default"
              end)

            {dns_entries, http_entries} = Enum.split_with(eligible, fn {_, dns?} -> dns? end)

            {Enum.map(http_entries, &elem(&1, 0)), Enum.map(dns_entries, &elem(&1, 0))}
          else
            {[], []}
          end

        new_https = Map.new(normalized, fn {name, _} -> {name, ssl_force_https?(service)} end)

        {http_acc ++ new_http, dns_acc ++ new_dns, Map.merge(https_acc, new_https)}
      end)

    Application.put_env(:elixirgateway, :letsencrypt_domains, http_domains)
    Application.put_env(:elixirgateway, :letsencrypt_wildcard_domains, dns_domains)

    existing = Application.get_env(:elixirgateway, :gateway, [])

    Application.put_env(
      :elixirgateway,
      :gateway,
      Keyword.put(existing, :force_https, force_https_map)
    )

    Logger.debug(
      "ConfigLoader: loaded #{length(http_domains)} HTTP-01 and #{length(dns_domains)} DNS-01 SSL domains"
    )
  end

  defp apply_ddns(services) do
    ddns_domains =
      Enum.flat_map(services, fn {_name, service} ->
        case Map.get(service, "ddns") do
          nil ->
            []

          ddns ->
            case Map.get(ddns, "provider", "namecheap") do
              "namecheap" ->
                [
                  %{
                    host: Map.fetch!(ddns, "record"),
                    domain: Map.fetch!(ddns, "domain"),
                    password: Map.fetch!(ddns, "token")
                  }
                ]

              "cloudflare" ->
                [
                  %{
                    host: Map.fetch!(ddns, "record"),
                    domain: Map.fetch!(ddns, "domain"),
                    password: "cloudflare"
                  }
                ]

              provider ->
                Logger.warning(
                  "ConfigLoader: DDNS provider '#{provider}' not yet supported, skipping"
                )

                []
            end
        end
      end)

    if ddns_domains != [] do
      cluster_config = Application.get_env(:elixirgateway, :cluster, [])
      dns_failover = Keyword.get(cluster_config, :dns_failover, [])
      updated_failover = Keyword.put(dns_failover, :domains, ddns_domains)

      Application.put_env(
        :elixirgateway,
        :cluster,
        Keyword.put(cluster_config, :dns_failover, updated_failover)
      )

      Logger.debug("ConfigLoader: loaded #{length(ddns_domains)} DDNS entries")
    end
  end

  # Builds a host-keyed map of path matchers (regex + method + timeout), mirroring
  # apply_services so DomainRouter can resolve a timeout the same way it resolves a target.
  defp apply_timeouts(services, default_timeout) do
    timeouts_map =
      services
      |> Enum.flat_map(fn {_name, service} ->
        timeout = Map.get(service, "timeout", default_timeout)
        path_matchers = build_path_matchers(service, timeout)

        service
        |> Map.get("domains", [])
        |> Enum.map(fn entry ->
          {name, _dns_challenge} = normalize_domain(entry)

          case name do
            "default" -> {"default_any", path_matchers}
            _ -> {name, path_matchers}
          end
        end)
      end)
      |> Map.new()

    existing = Application.get_env(:elixirgateway, :gateway, [])
    Application.put_env(:elixirgateway, :gateway, Keyword.put(existing, :timeouts, timeouts_map))

    Logger.debug("ConfigLoader: loaded timeouts for #{map_size(timeouts_map)} hosts")
  end

  defp build_path_matchers(service, default_timeout) do
    path_matchers =
      service
      |> Map.get("paths", %{})
      |> Enum.flat_map(fn {path_pattern, methods_map} ->
        Enum.map(methods_map, fn {method, path_config} ->
          %{
            pattern: Regex.compile!(path_pattern),
            method: method,
            timeout: Map.get(path_config, "timeout", default_timeout)
          }
        end)
      end)

    path_matchers ++ [%{pattern: ~r/.*/, method: ".*", timeout: default_timeout}]
  end

  # Domain entries can be a plain string or a map with name + optional dns_challenge flag.
  defp normalize_domain(domain) when is_binary(domain), do: {domain, false}

  defp normalize_domain(%{"name" => name} = entry),
    do: {name, Map.get(entry, "dns_challenge", false)}

  defp ssl_enabled?(service) do
    case Map.get(service, "ssl") do
      true -> true
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  defp ssl_force_https?(service) do
    case Map.get(service, "ssl") do
      true -> true
      %{"enabled" => true, "force_https" => false} -> false
      %{"enabled" => true} -> true
      _ -> false
    end
  end
end
