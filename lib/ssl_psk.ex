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
  def lookup(:psk, _psk_id, _user_state) do
    case System.get_env("CLUSTER_SECRET") do
      nil ->
        Logger.error("PSK authentication failed: CLUSTER_SECRET environment variable not set")
        :error

      secret when is_binary(secret) ->
        validate_and_decode_secret(secret)
    end
  end

  defp validate_and_decode_secret(secret) do
    case Base.decode16(secret, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) >= @min_secret_bytes ->
        {:ok, bytes}

      {:ok, bytes} ->
        Logger.error(
          "PSK authentication failed: secret too short (#{byte_size(bytes)} bytes, minimum #{@min_secret_bytes} bytes required)"
        )

        :error

      :error ->
        Logger.error(
          "PSK authentication failed: invalid hex encoding in CLUSTER_SECRET (expected hex string of at least #{@min_secret_bytes * 2} characters)"
        )

        :error
    end
  end
end
