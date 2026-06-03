defmodule ElixirGateway.Cluster.Jobs.CertRenewal do
  @moduledoc """
  Daily Quantum job that renews SSL certificates for all owned domains.

  Only runs on the primary node — secondary nodes receive updated certs via
  CertificateManager cluster sync after the primary renews them.

  Certbot skips domains whose certs are still valid for >30 days, so this
  is safe to run daily without hitting Let's Encrypt rate limits.
  """

  require Logger

  @renew_within_days 30

  def run do
    if primary_node?() do
      http_domains = Application.get_env(:elixirgateway, :letsencrypt_domains, [])
      dns_domains = Application.get_env(:elixirgateway, :letsencrypt_wildcard_domains, [])

      http_due = Enum.filter(http_domains, &needs_renewal?/1)
      dns_due = Enum.filter(dns_domains, &needs_renewal?/1)

      total = length(http_domains) + length(dns_domains)
      total_due = length(http_due) + length(dns_due)

      if total_due == 0 do
        Logger.info("CertRenewal: all #{total} cert(s) are up to date")
      else
        Logger.info(
          "CertRenewal: queuing renewal for #{total_due} domain(s): #{Enum.join(http_due ++ dns_due, ", ")}"
        )

        Enum.each(http_due, &ElixirGateway.CertbotRunner.ensure_cert/1)
        Enum.each(dns_due, &ElixirGateway.CertbotRunner.ensure_wildcard_cert/1)
      end
    else
      Logger.debug("CertRenewal: secondary node, skipping")
    end
  end

  def needs_renewal?(domain) do
    case ElixirGateway.CertStore.days_until_expiry(domain) do
      :no_cert -> true
      days -> days < @renew_within_days
    end
  end

  defp primary_node?, do: ElixirGateway.Cluster.Role.primary?()
end
