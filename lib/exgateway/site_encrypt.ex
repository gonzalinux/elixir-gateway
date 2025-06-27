defmodule Exgateway.SiteEncrypt do
  @moduledoc """
  SiteEncrypt configuration for automatic Let's Encrypt SSL certificates.
  """

  require Logger

  # Private helper functions
  def get_domains do
    case System.get_env("LETSENCRYPT_DOMAINS") do
      nil -> []
      domains_string -> 
        domains_string
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  def get_email do
    System.get_env("LETSENCRYPT_EMAIL")
  end

  def staging? do
    System.get_env("LETSENCRYPT_STAGING") == "true"
  end
end