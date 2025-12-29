defmodule ElixirGateway.UtilsTest do
  use ExUnit.Case, async: true

  alias ElixirGateway.Utils

  describe "exponential_backoff/2" do
    test "calculates exponential backoff with default settings" do
      # First attempt: 1000 * 2^0 = 1000ms, with 0-50% jitter = 1000-1500ms
      result = Utils.exponential_backoff(0)
      assert result >= 1000 and result <= 1500

      # Second attempt: 1000 * 2^1 = 2000ms, with 0-50% jitter = 2000-3000ms
      result = Utils.exponential_backoff(1)
      assert result >= 2000 and result <= 3000

      # Third attempt: 1000 * 2^2 = 4000ms, with 0-50% jitter = 4000-6000ms
      result = Utils.exponential_backoff(2)
      assert result >= 4000 and result <= 6000
    end

    test "respects custom base_delay" do
      # 100 * 2^0 = 100ms, with 0-50% jitter = 100-150ms
      result = Utils.exponential_backoff(0, base_delay: 100)
      assert result >= 100 and result <= 150

      # 100 * 2^2 = 400ms, with 0-50% jitter = 400-600ms
      result = Utils.exponential_backoff(2, base_delay: 100)
      assert result >= 400 and result <= 600
    end

    test "applies max_delay cap" do
      # 1000 * 2^10 = 1024000ms, but capped at 5000ms + jitter
      result = Utils.exponential_backoff(10, max_delay: 5000)
      assert result >= 5000 and result <= 7500
    end

    test "works with no jitter" do
      # Exact exponential backoff
      assert Utils.exponential_backoff(0, jitter: :none) == 1000
      assert Utils.exponential_backoff(1, jitter: :none) == 2000
      assert Utils.exponential_backoff(2, jitter: :none) == 4000
      assert Utils.exponential_backoff(3, jitter: :none) == 8000
    end

    test "applies fixed jitter (default 1000ms)" do
      # 1000 * 2^0 = 1000ms, with 0-1000ms jitter = 1000-2000ms
      result = Utils.exponential_backoff(0, jitter: :fixed)
      assert result >= 1000 and result <= 2000
    end

    test "applies custom fixed jitter" do
      # 1000 * 2^0 = 1000ms, with 0-500ms jitter = 1000-1500ms
      result = Utils.exponential_backoff(0, jitter: {:fixed, 500})
      assert result >= 1000 and result <= 1500
    end

    test "applies percentage jitter" do
      # 1000 * 2^0 = 1000ms, with 0-30% jitter = 1000-1300ms
      result = Utils.exponential_backoff(0, jitter: {:percentage, 30})
      assert result >= 1000 and result <= 1300

      # 1000 * 2^2 = 4000ms, with 0-25% jitter = 4000-5000ms
      result = Utils.exponential_backoff(2, jitter: {:percentage, 25})
      assert result >= 4000 and result <= 5000
    end

    test "raises on invalid jitter type" do
      assert_raise ArgumentError, ~r/Invalid jitter type/, fn ->
        Utils.exponential_backoff(0, jitter: :invalid)
      end
    end

    test "handles zero attempt number" do
      # 1000 * 2^0 = 1000ms
      result = Utils.exponential_backoff(0, jitter: :none)
      assert result == 1000
    end

    test "handles large attempt numbers with max_delay" do
      # Very large attempts should still respect max_delay
      result = Utils.exponential_backoff(100, max_delay: 10000, jitter: :none)
      assert result == 10000
    end
  end
end
