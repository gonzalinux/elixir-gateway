defmodule ElixirGateway.Cluster.SecretTest do
  use ExUnit.Case, async: true

  alias ElixirGateway.Cluster.Secret

  describe "generate/0" do
    test "generates a 64-character hex string" do
      secret = Secret.generate()

      assert is_binary(secret)
      assert String.length(secret) == 64
      assert String.match?(secret, ~r/^[0-9a-f]+$/)
    end

    test "generates unique secrets each time" do
      secret1 = Secret.generate()
      secret2 = Secret.generate()

      assert secret1 != secret2
    end
  end

  describe "validate/1" do
    test "accepts valid hex string of 64 characters" do
      valid_secret = String.duplicate("a", 64)
      assert :ok = Secret.validate(valid_secret)
    end

    test "accepts valid hex string longer than 32 characters" do
      valid_secret = String.duplicate("f", 65)
      assert :ok = Secret.validate(valid_secret)
    end

    test "rejects secret shorter than 32 characters" do
      short_secret = String.duplicate("a", 31)
      assert {:error, "Secret must be at least 32 characters long"} = Secret.validate(short_secret)
    end

    test "rejects secret with non-hex characters" do
      invalid_secret = "not-a-hex-string" <> String.duplicate("a", 32)
      assert {:error, "Secret must be hexadecimal (0-9, a-f)"} = Secret.validate(invalid_secret)
    end

    test "rejects non-string input" do
      assert {:error, "Secret must be a string"} = Secret.validate(123)
      assert {:error, "Secret must be a string"} = Secret.validate(nil)
      assert {:error, "Secret must be a string"} = Secret.validate(%{})
    end

    test "accepts uppercase hex characters" do
      valid_secret = String.duplicate("A", 64)
      assert :ok = Secret.validate(valid_secret)
    end

    test "accepts mixed case hex characters" do
      valid_secret = "aAbBcCdDeEfF" <> String.duplicate("0", 52)
      assert :ok = Secret.validate(valid_secret)
    end
  end

  describe "load_or_generate/1" do
    setup do
      # Store original env value
      original_value = System.get_env("CLUSTER_SECRET")

      on_exit(fn ->
        # Restore original value
        if original_value do
          System.put_env("CLUSTER_SECRET", original_value)
        else
          System.delete_env("CLUSTER_SECRET")
        end
      end)

      :ok
    end

    test "loads secret from environment variable" do
      test_secret = String.duplicate("a", 64)
      System.put_env("CLUSTER_SECRET", test_secret)

      assert ^test_secret = Secret.load_or_generate("CLUSTER_SECRET")
    end

    test "generates secret in dev mode if not set" do
      System.delete_env("CLUSTER_SECRET")

      # Capture IO to suppress warning
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          secret = Secret.load_or_generate("CLUSTER_SECRET")
          send(self(), {:secret, secret})
        end)

      assert_received {:secret, secret}
      assert is_binary(secret)
      assert String.length(secret) == 64
      assert output =~ "WARNING"
      assert output =~ "CLUSTER_SECRET"
    end

    test "validates secret from environment" do
      System.put_env("CLUSTER_SECRET", "invalid")

      assert_raise RuntimeError, ~r/Invalid cluster secret/, fn ->
        Secret.load_or_generate("CLUSTER_SECRET")
      end
    end

    test "uses custom environment variable name" do
      test_secret = String.duplicate("b", 64)
      System.put_env("CUSTOM_SECRET", test_secret)

      assert ^test_secret = Secret.load_or_generate("CUSTOM_SECRET")

      System.delete_env("CUSTOM_SECRET")
    end
  end
end
