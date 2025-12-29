defmodule ElixirGateway.SiteEncrypt do
  @moduledoc """
  SiteEncrypt configuration for automatic Let's Encrypt SSL certificates.
  """

  require Logger

  # Private helper functions
  def get_domains do
    case System.get_env("LETSENCRYPT_DOMAINS") do
      nil ->
        case Mix.env() do
          # Provide dummy domain for tests
          :test -> ["localhost"]
          :dev -> ["dev.example.com"]
          _ -> []
        end

      domains_string ->
        domains_string
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
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
