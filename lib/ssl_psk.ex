defmodule :ssl_psk do
  @moduledoc """
  PSK (Pre-Shared Key) lookup module for Erlang distribution with TLS.

  This module is referenced in the SSL distribution configuration file (priv/ssl_dist.conf)
  and is called by the Erlang SSL implementation during TLS handshake to retrieve
  the shared secret for PSK authentication.

  The secret is retrieved from the CLUSTER_SECRET environment variable, which should
  be a hex-encoded string of at least 32 bytes (64 hex characters).
  """

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
    secret = System.get_env("CLUSTER_SECRET")

    case Base.decode16(secret, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end
end
