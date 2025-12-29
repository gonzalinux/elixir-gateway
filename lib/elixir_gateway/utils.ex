defmodule ElixirGateway.Utils do
  @moduledoc """
  Utility functions used across the ElixirGateway application.
  """

  @doc """
  Calculates exponential backoff delay with optional jitter.

  ## Parameters

    * `attempt` - The attempt number (0-indexed or 1-indexed depending on usage)
    * `opts` - Keyword list of options:
      * `:base_delay` - Base delay in milliseconds (default: 1000)
      * `:max_delay` - Maximum delay cap in milliseconds (default: nil, no cap)
      * `:jitter` - Jitter type (default: :percentage_50)
        * `:none` - No jitter
        * `:fixed` - Fixed random jitter (0-1000ms)
        * `{:fixed, max_ms}` - Fixed random jitter (0-max_ms)
        * `:percentage_50` - 0-50% of computed backoff
        * `{:percentage, percent}` - 0-percent% of computed backoff

  ## Examples

      # Basic exponential backoff with 50% jitter (default)
      iex> ElixirGateway.Utils.exponential_backoff(0)
      # Returns 1000-1500ms

      # With max delay cap
      iex> ElixirGateway.Utils.exponential_backoff(5, base_delay: 1000, max_delay: 5000)
      # Returns max 5000ms + jitter

      # With fixed jitter
      iex> ElixirGateway.Utils.exponential_backoff(2, jitter: :fixed)
      # Returns 4000ms + (0-1000ms)

      # No jitter
      iex> ElixirGateway.Utils.exponential_backoff(3, jitter: :none)
      # Returns exactly 8000ms
  """
  @spec exponential_backoff(non_neg_integer(), keyword()) :: non_neg_integer()
  def exponential_backoff(attempt, opts \\ []) do
    base_delay = Keyword.get(opts, :base_delay, 1000)
    max_delay = Keyword.get(opts, :max_delay, nil)
    jitter_type = Keyword.get(opts, :jitter, :percentage_50)

    # Calculate exponential backoff: base * 2^attempt
    base_backoff = base_delay * :math.pow(2, attempt)

    # Apply max delay cap if specified
    capped_backoff = if max_delay, do: min(base_backoff, max_delay), else: base_backoff

    # Add jitter
    jitter = calculate_jitter(capped_backoff, jitter_type)

    trunc(capped_backoff + jitter)
  end

  defp calculate_jitter(_backoff, :none), do: 0

  defp calculate_jitter(_backoff, :fixed), do: :rand.uniform(1000)

  defp calculate_jitter(_backoff, {:fixed, max_ms}), do: :rand.uniform(max_ms)

  defp calculate_jitter(backoff, :percentage_50) do
    :rand.uniform(trunc(backoff * 0.5))
  end

  defp calculate_jitter(backoff, {:percentage, percent}) when percent > 0 and percent <= 100 do
    :rand.uniform(trunc(backoff * percent / 100))
  end

  defp calculate_jitter(_backoff, invalid) do
    raise ArgumentError, "Invalid jitter type: #{inspect(invalid)}"
  end
end
