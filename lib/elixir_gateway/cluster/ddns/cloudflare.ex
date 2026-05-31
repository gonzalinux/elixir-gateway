defmodule ElixirGateway.Cluster.DDNS.Cloudflare do
  @moduledoc """
  Cloudflare DDNS client using the Cloudflare API v4.

  Authentication uses one environment variable:
    - CLOUDFLARE_API_SECRET — API Token with Zone / DNS / Edit permission

  Zone IDs are auto-discovered from the domain name via the Cloudflare API.

  Domains are identified in DDNS_DOMAINS with the literal token "cloudflare":
    @:writeinone.com:cloudflare

  Records are updated preserving the existing proxied status; new records default to proxied: false. TTL is set to 60 seconds.
  """

  require Logger

  @base_url "https://api.cloudflare.com/client/v4"

  @doc """
  Updates all given domains with the new IP.
  Returns a list of {domain, host, result} tuples, matching the Namecheap client interface.
  The password field in each domain config is ignored (it holds the "cloudflare" sentinel).
  """
  def update_all(domains, ip) when is_list(domains) and is_binary(ip) do
    Enum.map(domains, fn %{host: host, domain: domain} ->
      result = update(host, domain, ip)
      log_result(host, domain, ip, result)
      {domain, host, result}
    end)
  end

  @doc "Updates a single host/domain A record to point to ip."
  def update(host, domain, ip) do
    with {:ok, token} <- get_token(),
         {:ok, zone_id} <- resolve_zone(domain, token),
         {:ok, record_id, proxied} <- find_record(host, domain, zone_id, token) do
      upsert_record(record_id, host, domain, zone_id, ip, proxied, token)
    end
  end

  ## Private

  defp get_token do
    case System.get_env("CLOUDFLARE_API_SECRET") do
      token when token not in [nil, ""] -> {:ok, token}
      _ -> {:error, :missing_cloudflare_api_secret}
    end
  end

  defp resolve_zone(domain, token), do: fetch_zone_id(domain, token)

  defp fetch_zone_id(domain, token) do
    case Req.get("#{@base_url}/zones", params: [name: domain], headers: auth_headers(token)) do
      {:ok, %{status: 200, body: %{"result" => [%{"id" => id} | _]}}} ->
        {:ok, id}

      {:ok, %{status: 200, body: %{"result" => []}}} ->
        {:error, {:zone_not_found, domain}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_record(host, domain, zone_id, token) do
    name = fqdn(host, domain)

    case Req.get("#{@base_url}/zones/#{zone_id}/dns_records",
           params: [type: "A", name: name],
           headers: auth_headers(token)
         ) do
      {:ok, %{status: 200, body: %{"result" => [%{"id" => id, "proxied" => proxied} | _]}}} ->
        {:ok, id, proxied}

      {:ok, %{status: 200, body: %{"result" => []}}} ->
        {:ok, nil, false}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_record(nil, host, domain, zone_id, ip, proxied, token) do
    body = record_body(host, domain, ip, proxied)

    case Req.post("#{@base_url}/zones/#{zone_id}/dns_records",
           json: body,
           headers: auth_headers(token)
         ) do
      {:ok, %{body: %{"success" => true}}} -> :ok
      {:ok, %{body: %{"errors" => errors}}} -> {:error, {:api_error, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_record(record_id, host, domain, zone_id, ip, proxied, token) do
    body = record_body(host, domain, ip, proxied)

    case Req.patch("#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}",
           json: body,
           headers: auth_headers(token)
         ) do
      {:ok, %{body: %{"success" => true}}} -> :ok
      {:ok, %{body: %{"errors" => errors}}} -> {:error, {:api_error, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_body(host, domain, ip, proxied) do
    %{type: "A", name: fqdn(host, domain), content: ip, ttl: 60, proxied: proxied}
  end

  defp fqdn("@", domain), do: domain
  defp fqdn(host, domain), do: "#{host}.#{domain}"

  defp auth_headers(token), do: [{"Authorization", "Bearer #{token}"}]

  defp log_result(host, domain, ip, :ok) do
    Logger.info("Cloudflare DDNS: #{fqdn(host, domain)} → #{ip}")
  end

  defp log_result(host, domain, ip, {:error, reason}) do
    Logger.error("Cloudflare DDNS: #{fqdn(host, domain)} → #{ip} failed: #{inspect(reason)}")
  end
end
