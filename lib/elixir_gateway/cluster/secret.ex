defmodule ElixirGateway.Cluster.Secret do
  @moduledoc """
  Helper module for generating and managing cluster secrets.

  Cluster secrets are used for encrypting communication between nodes.
  All nodes in a cluster must share the same secret.
  """

  @secret_length 32

  @doc """
  Generates a random cluster secret.

  Returns a hex-encoded string suitable for use as CLUSTER_SECRET.
  """
  def generate do
    :crypto.strong_rand_bytes(@secret_length)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Validates that a secret meets security requirements.

  Returns:
  - `:ok` if valid
  - `{:error, reason}` if invalid
  """
  def validate(secret) when is_binary(secret) do
    cond do
      String.length(secret) < 32 ->
        {:error, "Secret must be at least 32 characters long"}

      not String.match?(secret, ~r/^[0-9a-fA-F]+$/) ->
        {:error, "Secret must be hexadecimal (0-9, a-f)"}

      true ->
        :ok
    end
  end

  def validate(_) do
    {:error, "Secret must be a string"}
  end

  @doc """
  Loads the cluster secret from environment or generates one if missing.

  This should only be used in development. In production, secrets should
  always be explicitly configured.
  """
  def load_or_generate(env \\ "CLUSTER_SECRET") do
    case System.get_env(env) do
      nil ->
        if Mix.env() in [:dev, :test] do
          secret = generate()
          IO.puts(:stderr, """
          WARNING: No #{env} found, generated temporary secret for development.
          This secret will not persist across restarts.

          To use clustering, set a permanent secret:
            export #{env}=#{secret}

          Or generate a new one:
            mix elixir_gateway.gen.cluster_secret
          """)

          secret
        else
          raise """
          Clustering is enabled but #{env} is not set.

          Generate a secret with:
            mix elixir_gateway.gen.cluster_secret

          Then set it in your environment:
            export #{env}=<generated-secret>
          """
        end

      secret ->
        case validate(secret) do
          :ok ->
            secret

          {:error, reason} ->
            raise "Invalid cluster secret: #{reason}"
        end
    end
  end
end
