defmodule :ssl_psk do
  @moduledoc """
  PSK (Pre-Shared Key) lookup module for Erlang distribution with TLS.

  This module is referenced in the SSL distribution configuration file (priv/ssl_dist.conf)
  and is called by the Erlang SSL implementation during TLS handshake to retrieve
  the shared secret for PSK authentication.

  The secret is retrieved from the CLUSTER_SECRET environment variable, which should
  be a hex-encoded string of at least 32 bytes (64 hex characters).
  """

  require Logger

  @min_secret_bytes 32

  @doc """
  Lookup function for PSK authentication.

  Called by Erlang SSL during TLS handshake to retrieve the pre-shared key.

  ## Parameters
  - `:psk` - The authentication method (always :psk)
  - `_psk_id` - The PSK identity (unused in our implementation)
  - `_user_state` - User-defined state (unused in our implementation)

  ## Returns
  - `{:ok, binary()}` - The decoded secret as binary
  - `:error` - If the secret is invalid or missing
  """
  def lookup(:psk, psk_id, _user_state) do
    Logger.info("PSK lookup called - PSK ID: #{inspect(psk_id)}")

    case System.get_env("CLUSTER_SECRET") do
      nil ->
        Logger.error("PSK authentication failed: no secret was found")
        :error

      secret when is_binary(secret) ->
        Logger.debug("PSK secret found, validating...")
        result = validate_and_decode_secret(secret)

        case result do
          {:ok, _bytes} ->
            Logger.info("✓ PSK authentication successful")

          :error ->
            Logger.error("✗ PSK validation failed")
        end

        result
    end
  end

  defp validate_and_decode_secret(secret) do
    case Base.decode16(secret, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) >= @min_secret_bytes ->
        Logger.debug("Secret is valid")
        {:ok, bytes}

      {:ok, _bytes} ->
        Logger.error("PSK authentication failed: the secret is less than #{@min_secret_bytes}")

        :error

      :error ->
        Logger.error("PSK authentication failed: the secret could not be decoded")
        :error
    end
  end
end
