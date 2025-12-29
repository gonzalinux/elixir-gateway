defmodule ElixirGateway.Cluster.DDNS.Namecheap do
  @moduledoc """
  Namecheap DDNS client. Same protocol as ddclient.
  No API key needed — just the DDNS password from Namecheap dashboard.

  Enable Dynamic DNS for your domain in Namecheap dashboard:
  1. Go to Domain List → Manage → Advanced DNS
  2. Enable "Dynamic DNS"
  3. Copy the DDNS password for each host/domain pair

  Protocol: https://www.namecheap.com/support/knowledgebase/article.aspx/29/11/how-to-dynamically-update-the-hosts-ip-with-an-http-request/
  """

  require Logger

  alias ElixirGateway.Cluster.IPDetection

  @ddns_url "https://dynamicdns.park-your-domain.com/update"

  @doc """
  Updates all configured domains with the specified IP address.

  Returns a list of {domain, host, result} tuples.
  """
  def update_all(domains, ip) when is_list(domains) and is_binary(ip) do
    Enum.map(domains, fn domain_config ->
      %{host: host, domain: domain, password: password} = domain_config
      result = update(host, domain, password, ip)

      log_update_result(host, domain, ip, result)

      {domain, host, result}
    end)
  end

  @doc """
  Updates a single domain/host pair with the specified IP address.

  ## Parameters
  - host: The subdomain host ("@" for root, "www", "api", etc.)
  - domain: The domain name (e.g., "example.com")
  - password: The DDNS password from Namecheap dashboard
  - ip: The IP address to set (IPv4)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  def update(host, domain, password, ip) do
    url = build_update_url(host, domain, password, ip)

    # Disable auto-decoding since Namecheap returns XML, not JSON
    case Req.get(url, decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: status, body: body}} ->
        Logger.error("DDNS update failed with status #{status}: #{body}")
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        Logger.error("DDNS update request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the public IP address of this server.

  Delegates to ElixirGateway.Cluster.IPDetection.
  Returns {:ok, ip} or {:error, reason}.
  """
  def get_public_ip do
    IPDetection.get_public_ip()
  end

  ## Private Functions

  defp build_update_url(host, domain, password, ip) do
    # URL encode parameters
    params =
      URI.encode_query(%{
        host: host,
        domain: domain,
        password: password,
        ip: ip
      })

    "#{@ddns_url}?#{params}"
  end

  defp parse_response(body) do
    cond do
      # Success response
      String.contains?(body, "<ErrCount>0</ErrCount>") ->
        :ok

      # Extract error from XML response
      error_match = Regex.run(~r/<Err1>(.*?)<\/Err1>/, body) ->
        [_, error] = error_match
        {:error, "DDNS error: #{error}"}

      # Unknown response format
      true ->
        {:error, "Unknown response: #{body}"}
    end
  end

  defp log_update_result(host, domain, ip, result) do
    full_domain = if host == "@", do: domain, else: "#{host}.#{domain}"

    case result do
      :ok ->
        Logger.info("DDNS update successful: #{full_domain} → #{ip}")

      {:error, reason} ->
        Logger.error("DDNS update failed: #{full_domain} → #{ip} (#{inspect(reason)})")
    end
  end
end
