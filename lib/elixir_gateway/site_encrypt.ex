defmodule ElixirGateway.SiteEncrypt do
  @moduledoc """
  SiteEncrypt configuration for automatic Let's Encrypt SSL certificates.
  """

  require Logger

  # Private helper functions
  def get_domains do
    Application.get_env(:elixirgateway, :letsencrypt_domains) || default_domains()
  end

  defp default_domains do
    case Mix.env() do
      :test -> ["localhost"]
      :dev -> ["dev.example.com"]
      _ -> []
    end
  end

  def get_email do
    case System.get_env("LETSENCRYPT_EMAIL") do
      nil ->
        case Mix.env() do
          # Provide dummy email for tests
          :test -> "test@example.com"
          :dev -> "test@example.com"
          _ -> nil
        end

      email ->
        email
    end
  end

  def staging? do
    System.get_env("LETSENCRYPT_STAGING") == "true"
  end
end
