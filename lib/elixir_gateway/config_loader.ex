defmodule ElixirGateway.ConfigLoader do
  @moduledoc """
  Loads gateway configuration from a YAML file and populates Application env.

  Reads from the path in GATEWAY_CONFIG_FILE env var, falling back to
  priv/gateway.yaml. If neither exists, does nothing and existing env var
  config continues to work unchanged.

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
      Logger.debug("ConfigLoader: no config file found at #{path}, loading from env vars")
      load_from_env()
    end
  end

  def load_from_env do
    apply_services_from_env()
    apply_ssl_domains_from_env()
  end

  defp apply_services_from_env do
    with services_str when not is_nil(services_str) <- System.get_env("GATEWAY_SERVICES") do
      services =
        services_str
        |> String.split(";", trim: true)
        |> Enum.map(fn mapping ->
          case String.split(mapping, "=>", parts: 2) do
            [host, target] -> {String.trim(host), String.trim(target)}
            _ -> raise "ConfigLoader: invalid GATEWAY_SERVICES entry: #{mapping}"
          end
        end)
        |> Map.new()

      existing = Application.get_env(:elixirgateway, :gateway, [])
      Application.put_env(:elixirgateway, :gateway, Keyword.put(existing, :services, services))
    end
  end

  defp apply_ssl_domains_from_env do
    with domains_str when not is_nil(domains_str) <- System.get_env("LETSENCRYPT_DOMAINS") do
      domains =
        domains_str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      Application.put_env(:elixirgateway, :letsencrypt_domains, domains)
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

    apply_services(services)
    apply_ssl_domains(services)
    apply_ddns(services)
  end

  defp apply_services(services) do
    routing_map =
      services
      |> Enum.flat_map(fn {_name, service} ->
        target = Map.fetch!(service, "target")

        service
        |> Map.get("domains", [])
        |> Enum.map(fn
          "default" -> {"default_any", target}
          domain -> {domain, target}
        end)
      end)
      |> Map.new()

    existing = Application.get_env(:elixirgateway, :gateway, [])
    Application.put_env(:elixirgateway, :gateway, Keyword.put(existing, :services, routing_map))

    Logger.debug("ConfigLoader: loaded #{map_size(routing_map)} service routes")
  end

  defp apply_ssl_domains(services) do
    {ssl_domains, force_https_map} =
      Enum.reduce(services, {[], %{}}, fn {_name, service}, {domains_acc, https_acc} ->
        service_domains = Map.get(service, "domains", [])

        new_domains =
          if ssl_enabled?(service) do
            service_domains
            |> Enum.reject(&String.starts_with?(&1, "*"))
            |> Enum.reject(&(&1 == "default"))
          else
            []
          end

        new_https =
          Map.new(service_domains, fn domain -> {domain, ssl_force_https?(service)} end)

        {domains_acc ++ new_domains, Map.merge(https_acc, new_https)}
      end)

    Application.put_env(:elixirgateway, :letsencrypt_domains, ssl_domains)

    existing = Application.get_env(:elixirgateway, :gateway, [])

    Application.put_env(
      :elixirgateway,
      :gateway,
      Keyword.put(existing, :force_https, force_https_map)
    )

    Logger.debug("ConfigLoader: loaded #{length(ssl_domains)} SSL domains")
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
