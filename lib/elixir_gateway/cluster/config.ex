defmodule ElixirGateway.Cluster.Config do
  @moduledoc """
  Shared configuration helpers for cluster-related features.

  Provides centralized access to cluster configuration to avoid duplication
  across multiple modules.
  """

  @doc """
  Returns true if load distribution is enabled in configuration.

  Load distribution requires clustering to be enabled and the load_distribution
  config to have `enabled: true`.

  ## Examples

      iex> ElixirGateway.Cluster.Config.load_distribution_enabled?()
      true

  """
  @spec load_distribution_enabled?() :: boolean()
  def load_distribution_enabled? do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    load_dist_config = cluster_config[:load_distribution] || []
    load_dist_config[:enabled] == true
  end

  @doc """
  Returns the full load distribution configuration.

  ## Examples

      iex> ElixirGateway.Cluster.Config.load_distribution_config()
      [enabled: true, node_weight: 70, min_requests_threshold: 20, window_seconds: 60]

  """
  @spec load_distribution_config() :: keyword()
  def load_distribution_config do
    cluster_config = Application.get_env(:elixirgateway, :cluster, [])
    cluster_config[:load_distribution] || [enabled: false]
  end

  @doc """
  Returns true if clustering is enabled in configuration.

  ## Examples

      iex> ElixirGateway.Cluster.Config.clustering_enabled?()
      true

  """
  @spec clustering_enabled?() :: boolean()
  def clustering_enabled? do
    config = Application.get_env(:elixirgateway, :cluster, [])
    Keyword.get(config, :enabled, false)
  end
end
