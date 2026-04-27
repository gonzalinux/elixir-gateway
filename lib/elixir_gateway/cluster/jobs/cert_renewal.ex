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
      domains = Application.get_env(:elixirgateway, :letsencrypt_domains, [])
      due = Enum.filter(domains, &needs_renewal?/1)

      if due == [] do
        Logger.info("CertRenewal: all #{length(domains)} cert(s) are up to date")
      else
        Logger.info("CertRenewal: queuing renewal for #{length(due)} domain(s): #{Enum.join(due, ", ")}")
        Enum.each(due, &ElixirGateway.CertbotRunner.ensure_cert/1)
      end
    else
      Logger.debug("CertRenewal: secondary node, skipping")
    end
  end

  defp needs_renewal?(domain) do
    case ElixirGateway.CertStore.days_until_expiry(domain) do
      :no_cert -> true
      days -> days < @renew_within_days
    end
  end

  defp primary_node? do
    System.get_env("IS_PRIMARY") != "false"
  end
end
